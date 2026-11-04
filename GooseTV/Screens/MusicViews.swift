import SwiftUI

// MARK: - Pictures and cards

/// An album's, a playlist's or an artist's picture, square.
struct MusicArt: View {
    @Environment(\.appState) private var app
    let item: BaseItem
    var maxWidth = 440

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(url: keptCover ?? app?.client?.imageURL(for: item, type: "Primary", maxWidth: maxWidth),
                            symbol: item.isArtist ? "music.mic" : "music.note")
            }
            .clipped()
            // Touches inside the frame only: a filled picture spills past it.
            .contentShape(.interaction, Rectangle())
    }

    /// The cover kept with a downloaded song, album or playlist, which shows
    /// without the server.
    private var keptCover: URL? {
        #if !os(tvOS)
        Downloads.shared.imageURL(item.id)
        #else
        nil
        #endif
    }
}

/// An album or a playlist of songs: its cover, its name and who it's by,
/// opening its page.
struct AlbumCard: View {
    @Environment(\.sectionNavigator) private var navigator
    let item: BaseItem
    /// Fixed width for shelves; nil fills the grid's cell.
    var width: CGFloat? = nil
    /// What the second line says: who it's by, by default, or its year on an artist's own page.
    var note: String? = nil
    /// For a row that keeps its own focus (the Apple TV's Home), and the
    /// card's name in it.
    var focus: FocusState<String?>.Binding? = nil
    var focusID: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item) {
                MusicArt(item: item)
                    .keepsCardCorners()
                    .frame(width: width)
            }
            .buttonStyle(.tvCard)
            .focused(by: focus, id: focusID ?? item.id)
            .itemContextMenu(item, offersPlay: true, moreActions: { MusicMenu.goTo(item, navigator) })
            .accessibilityLabel([item.displayTitle, item.byLine].compactMap { $0 }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.app(16))
                    .lineLimit(1)
                if let line = note ?? item.byLine ?? item.productionYear.map(String.init) {
                    Text(line)
                        .font(.app(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }
}

/// A song on its own, square as an album is: its cover, its name and who
/// sings it. Chosen, it plays (the row it's in decides what follows it).
struct SongCard: View {
    @Environment(\.sectionNavigator) private var navigator
    let item: BaseItem
    var width: CGFloat? = nil
    var focus: FocusState<String?>.Binding? = nil
    var focusID: String? = nil
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                MusicArt(item: item)
                    .overlay(alignment: .bottomTrailing) {
                        PlayingMark(songId: item.id, covers: true)
                            .frame(width: 44, height: 44)
                            .padding(10)
                    }
                    .keepsCardCorners()
                    .frame(width: width)
            }
            .buttonStyle(.tvCard)
            .focused(by: focus, id: focusID ?? item.id)
            .itemContextMenu(item, moreActions: { MusicMenu.goTo(item, navigator) })
            .accessibilityLabel([item.displayTitle, item.byLine].compactMap { $0 }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.app(16))
                    .lineLimit(1)
                if let line = item.byLine {
                    Text(line)
                        .font(.app(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }
}

/// Someone who made albums: their picture and name, opening their page.
struct ArtistCard: View {
    let item: BaseItem
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item) {
                MusicArt(item: item)
                    .keepsCardCorners()
                    .frame(width: width)
            }
            .buttonStyle(.tvCard)
            .itemContextMenu(item, offersPlay: true)
            .accessibilityLabel(item.displayTitle)
            Text(item.displayTitle)
                .font(.app(16))
                .lineLimit(1)
                .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }
}

/// The first card among the playlists, which makes a new one.
struct NewPlaylistCard: View {
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        ZStack {
                            Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing).opacity(0.3)
                            Image(systemName: "plus")
                                .font(.app(44, .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .keepsCardCorners()
            }
            .buttonStyle(.tvCard)
            .accessibilityLabel(String(localized: "New Playlist", comment: "Title of the panel naming a new playlist of songs"))
            Text(String(localized: "New Playlist", comment: "Title of the panel naming a new playlist of songs"))
                .font(.app(16))
                .lineLimit(1)
        }
    }
}

/// A kind of music, opening its albums: its name over the picture the
/// server made of it, or the scheme's colours where it made none.
struct GenreCard: View {
    @Environment(\.appState) private var app
    let genre: BaseItem
    let library: BaseItem
    /// Its place in the list, for its colours.
    let place: Int

    var body: some View {
        NavigationLink(value: MusicRoute(kind: .genre, id: genre.id, name: genre.displayTitle, parent: library.id)) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    ZStack(alignment: .bottomLeading) {
                        Theme.gradient(Theme.palette[place % Theme.palette.count], start: .topLeading, end: .bottomTrailing)
                        if genre.imageTags?["Primary"] != nil {
                            // Held to the tile: filling it, a square picture
                            // made the tile as tall as itself, and the name
                            // at its foot fell out of sight.
                            Color.clear
                                .overlay {
                                    RemoteImage(url: app?.client?.imageURL(for: genre, type: "Primary", maxWidth: 600), symbol: "music.note")
                                }
                                .clipped()
                                .contentShape(.interaction, Rectangle())
                                .opacity(0.45)
                        }
                        LinearGradient(colors: [.clear, .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(genre.displayTitle)
                                .font(.app(Theme.isPhone ? 19 : 26, .bold))
                                .lineLimit(2)
                            if let counts {
                                Text(counts)
                                    .font(.app(Theme.isPhone ? 13 : 15))
                                    .opacity(0.8)
                            }
                        }
                        .foregroundStyle(.white)
                        .padding(CGFloat(Theme.isPhone ? 12 : 20))
                    }
                }
                .keepsCardCorners()
        }
        .buttonStyle(.tvCard)
        .accessibilityLabel([genre.displayTitle, counts].compactMap { $0 }.joined(separator: ", "))
    }

    /// "4 albums".
    private var counts: String? {
        guard let albums = genre.albumCount, albums > 0 else { return nil }
        return String(localized: "\(albums) albums")
    }
}

/// A song in a list: its number on the album (or its cover in a list of
/// songs from everywhere), its name and who sings it where that isn't the
/// album's artist, and how long it is. Chosen, it plays, and the songs
/// after it follow.
struct TrackRow: View {
    @Environment(\.sectionNavigator) private var navigator
    let song: BaseItem
    /// Its number on the album; nil shows its cover instead.
    var number: Int? = nil
    /// Who sings it, under its name.
    var showsArtist = false
    /// …and from which album.
    var showsAlbum = false
    /// Being moved along a playlist (the Apple TV's way of reordering one):
    /// marked so, in place of its number or cover.
    var moving = false
    /// Rows of the page's own for its long-press menu (a playlist's moves).
    var menuActions: (() -> [ItemMenuAction])? = nil
    let play: () -> Void

    var body: some View {
        Button(action: play) {
            HStack(spacing: CGFloat(16).scaled) {
                ZStack {
                    if moving {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.app(20, .bold))
                    } else if let number {
                        Text("\(number)")
                            .font(.app(18, .semibold))
                            .monospacedDigit()
                            .opacity(0.6)
                            .hiddenWhilePlaying(song.id)
                    } else {
                        MusicArt(item: song, maxWidth: 120)
                            .frame(width: CGFloat(48).scaled, height: CGFloat(48).scaled)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    if !moving { PlayingMark(songId: song.id, covers: number == nil) }
                }
                // The same height whether it shows a number or the mark.
                .frame(width: CGFloat(48).scaled, height: CGFloat(number == nil ? 48 : 30).scaled)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(song.displayTitle)
                            .font(.app(20, .semibold))
                            .lineLimit(1)
                        FavoriteMark(item: song)
                    }
                    if let line = subtitle {
                        Text(line)
                            .font(.app(15))
                            .opacity(0.6)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 12)
                if let length = song.songLength {
                    Text(length)
                        .font(.app(17))
                        .monospacedDigit()
                        .opacity(0.6)
                }
            }
        }
        .buttonStyle(TrackRowStyle())
        .itemContextMenu(song, moreActions: { MusicMenu.goTo(song, navigator) + (menuActions?() ?? []) })
        .accessibilityLabel([song.displayTitle, subtitle, song.songLength].compactMap { $0 }.joined(separator: ", "))
    }

    private var subtitle: String? {
        let parts = [showsArtist ? song.byLine : nil, showsAlbum ? song.album : nil].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A list row lit white when it has focus, as the long-press menu's rows are.
struct TrackRowStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused ? Color.black : .white)
            .padding(.vertical, CGFloat(Theme.isPhone ? 8 : 10).scaled)
            .padding(.horizontal, CGFloat(14).scaled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(focused ? Color.white : configuration.isPressed ? .white.opacity(0.08) : .clear))
            .pointerWash(cornerRadius: 12)
            .shadow(color: focused ? .black.opacity(0.35) : .clear, radius: 14, y: 5)
            .scaleEffect(focused ? 1.02 : 1)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// Marks the song playing, wherever it's listed: a speaker that moves while
/// it plays. Watches the player itself, so the list around it isn't redrawn.
struct PlayingMark: View {
    @ObservedObject private var music = MusicPlayer.shared
    let songId: String
    /// Over a cover, on a dark disc so it reads.
    var covers = false

    var body: some View {
        if music.current?.id == songId {
            Image(systemName: "speaker.wave.2.fill")
                .font(.app(17, .bold))
                .symbolEffect(.variableColor.iterative, isActive: music.isPlaying)
                .foregroundStyle(Theme.primary.1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(covers ? Color.black.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .accessibilityLabel(String(localized: "Playing", comment: "Marks the song playing in a list of songs"))
        }
    }
}

// MARK: - Favourites

/// Songs, albums and artists made favourites, or unmade, from this device:
/// the latest answer known for each, and when it was known. So the star
/// beside a song, on a page or in Now Playing, says how things stand rather
/// than how they stood when it was listed; and a page fetched again after
/// that (a star changed on another device) has the last word. Watched only
/// by those stars.
@MainActor
final class MusicFavorites: ObservableObject {
    static let shared = MusicFavorites()

    private struct Known: Equatable {
        let favorite: Bool
        /// When the server was known to say so; `distantFuture` while it's
        /// still being told, so nothing fetched meanwhile undoes it.
        let at: Date
    }

    @Published private var known: [String: Known] = [:]

    func isFavorite(_ item: BaseItem) -> Bool { known[item.id]?.favorite ?? item.userData?.isFavorite ?? false }

    /// What the server said in a fetch asked at `asked`: it stands for those
    /// this device has changed, unless they've changed again since.
    func heard(_ items: [BaseItem], askedAt asked: Date) {
        guard !known.isEmpty else { return }
        var next = known
        for item in items {
            guard let was = next[item.id], was.at < asked, let now = item.userData?.isFavorite else { continue }
            next[item.id] = Known(favorite: now, at: asked)
        }
        if next != known { known = next }
    }

    /// Another account's are another matter.
    func reset() { if !known.isEmpty { known = [:] } }

    /// Marks it or unmarks it at once, and tells the server; puts it back if
    /// the server refuses.
    func toggle(_ item: BaseItem, app: AppState?) {
        guard let client = app?.client else { return }
        let wanted = !isFavorite(item)
        let before = known[item.id]
        known[item.id] = Known(favorite: wanted, at: .distantFuture)
        Task {
            do {
                try await client.setFavorite(item.id, wanted)
                known[item.id] = Known(favorite: wanted, at: Date())
                app?.userDataChanged(favorites: true)
            } catch {
                known[item.id] = before
            }
        }
    }
}

/// A small star beside a favourite song's name.
struct FavoriteMark: View {
    @ObservedObject private var favorites = MusicFavorites.shared
    let item: BaseItem

    var body: some View {
        if favorites.isFavorite(item) {
            Image(systemName: "star.fill")
                .font(.app(13, .bold))
                .foregroundStyle(Theme.primary.1)
                .accessibilityLabel(String(localized: "Favourite", comment: "Marks a favourite song in a list of songs"))
        }
    }
}

/// The star that makes a song, an album or an artist a favourite, round.
struct MusicFavoriteButton: View {
    @Environment(\.appState) private var app
    @ObservedObject private var favorites = MusicFavorites.shared
    let item: BaseItem

    var body: some View {
        let on = favorites.isFavorite(item)
        Button { favorites.toggle(item, app: app) } label: {
            Image(systemName: on ? "star.fill" : "star")
        }
        .buttonStyle(.action(active: on))
        .accessibilityLabel(on ? String(localized: "Remove from favourites") : String(localized: "Add to favourites"))
    }
}

private extension View {
    /// Gone while the song is the one playing, for the mark in its place.
    func hiddenWhilePlaying(_ songId: String) -> some View {
        modifier(HiddenWhilePlaying(songId: songId))
    }
}

private struct HiddenWhilePlaying: ViewModifier {
    @ObservedObject private var music = MusicPlayer.shared
    let songId: String

    func body(content: Content) -> some View {
        content.opacity(music.current?.id == songId ? 0 : 1)
    }
}

// MARK: - Menus

/// What the long-press menus of music offer that only the screen can do:
/// go to the album or the artist.
enum MusicMenu {
    static func goTo(_ item: BaseItem, _ navigator: SectionNavigator) -> [ItemMenuAction] {
        var rows: [ItemMenuAction] = []
        if item.isSong, let album = item.albumId {
            rows.append(.init(title: String(localized: "Go to Album"), icon: "square.stack") {
                navigator.showMusic(MusicRoute(kind: .album, id: album, name: item.album))
            })
        }
        if item.isSong || item.isAlbum, let artist = item.leadArtist {
            rows.append(.init(title: String(localized: "Go to Artist"), icon: "music.mic") {
                navigator.showMusic(MusicRoute(kind: .artist, id: artist.id, name: artist.name))
            })
        }
        return rows
    }

    /// Every song of a song, an album, a playlist or an artist, in order.
    static func songs(of item: BaseItem, client: any MediaServer) -> () async throws -> [BaseItem] {
        if item.isSong { return { [item] } }
        if item.isArtist { return { try await client.songs(by: item.id, shuffled: false, limit: 1000) } }
        return { try await client.tracks(of: item.id, playlist: item.type == "Playlist") }
    }
}

// MARK: - A music library

enum MusicTab: String, CaseIterable, Identifiable {
    case albums, artists, songs, genres, playlists, favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .albums: String(localized: "Albums", comment: "Music library: its albums")
        case .artists: String(localized: "Artists", comment: "Music library: who made its albums")
        case .songs: String(localized: "Songs", comment: "Music library: every song in it")
        case .genres: String(localized: "Genres", comment: "Music library: its kinds of music")
        case .playlists: String(localized: "Playlists", comment: "Music library: the server's playlists of songs")
        case .favorites: String(localized: "Favourites", comment: "Music library: the songs, albums and artists marked favourite")
        }
    }

    var kind: MusicKind? {
        switch self {
        case .albums: .albums
        case .artists: .artists
        case .songs: .songs
        case .genres, .playlists, .favorites: nil
        }
    }

    var sorts: [MusicSort] {
        switch self {
        case .albums: [.title, .artist, .year, .added]
        case .songs: [.title, .artist, .album, .added, .mostPlayed]
        case .artists, .genres, .playlists, .favorites: []
        }
    }
}

enum MusicSort: String, CaseIterable {
    case title, artist, album, year, added, mostPlayed

    var title: String {
        switch self {
        case .title: String(localized: "Title")
        case .artist: String(localized: "Artist", comment: "Music: sort by who made it")
        case .album: String(localized: "Album", comment: "Music: sort songs by their album")
        case .year: String(localized: "Year", comment: "Music: sort albums by when they came out, newest first")
        case .added: String(localized: "Recently Added")
        case .mostPlayed: String(localized: "Most Played", comment: "Music: sort songs by how often they've been played")
        }
    }

    /// The server's sort for it.
    func api(for tab: MusicTab) -> (by: String, order: String) {
        switch self {
        // A song's SortName is the server's "0001 - 0003 - Name" (disc and
        // track first): songs sorted by it came out in track order.
        case .title: (tab == .songs ? "Name" : "SortName", "Ascending")
        case .artist: tab == .albums ? ("AlbumArtist,SortName", "Ascending") : ("Artist,Album,ParentIndexNumber,IndexNumber", "Ascending")
        case .album: ("Album,ParentIndexNumber,IndexNumber", "Ascending")
        case .year: ("ProductionYear,SortName", "Descending")
        case .added: ("DateCreated,SortName", "Descending")
        case .mostPlayed: ("PlayCount,SortName", "Descending")
        }
    }
}

/// A music library: its albums, artists, songs, and the server's playlists
/// of songs, with Shuffle All over the lot.
struct MusicLibraryView: View {
    @EnvironmentObject var app: AppState
    let library: BaseItem

    @State private var tab: MusicTab
    @State private var sort: MusicSort
    @State private var items: [BaseItem] = []
    /// Favourites: the albums and artists above the songs (`items`).
    @State private var favoriteAlbums: [BaseItem] = []
    @State private var favoriteArtists: [BaseItem] = []
    @State private var total: Int?
    @State private var loaded = false
    /// The tab and sort the list was read for.
    @State private var shownKey = ""
    @State private var loadingMore = false
    @State private var namingPlaylist = false
    @State private var playlistFailed = false

    private static let page = 100

    init(library: BaseItem) {
        self.library = library
        let saved = UserDefaults.standard.string(forKey: Self.tabKey(library.id)).flatMap(MusicTab.init(rawValue:)) ?? .albums
        _tab = State(initialValue: saved)
        _sort = State(initialValue: saved.sorts.first ?? .title)
    }

    private static func tabKey(_ id: String) -> String { "goosetv.music.tab.\(id)" }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.posterWidth * (Theme.isPhone ? 1 : 1.0)), spacing: Theme.isPhone ? 16 : 36, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                    .tvFocusSection()
                tabs
                    .tvFocusSection()
                // A region, so down from any of the kinds above lands in it,
                // whichever card lies under that kind's button.
                content
                    .tvFocusSection()
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, Theme.isPhone ? 20 : 48)
        }
        .pageSides()
        .task(id: "\(tab.rawValue)/\(sort.rawValue)") {
            // Back from an album: the list stays as it was, focus on the
            // card it was opened from. Read afresh, the grid went for a
            // moment and focus fell to the tabs.
            let key = "\(tab.rawValue)/\(sort.rawValue)"
            guard key != shownKey || !loaded else { return }
            shownKey = key
            await load(fresh: true)
        }
        // A playlist made, changed or deleted here; a favourite marked.
        .onReceive(NotificationCenter.default.publisher(for: .songPlaylistsChanged)) { _ in
            if tab == .playlists { Task { await load(fresh: false) } }
        }
        .onChange(of: app.userDataRevision) { _, _ in
            if tab == .favorites { Task { await load(fresh: false) } }
        }
        .fullScreenCover(isPresented: $namingPlaylist) {
            TextEntryPanel(title: String(localized: "New Playlist", comment: "Title of the panel naming a new playlist of songs"),
                           message: String(localized: "What to call it. Songs go in from their long-press menu: Add to Playlist.",
                                           comment: "Asks for a new, empty playlist's name, and says how songs are put in it"),
                           placeholder: PlaylistPicker.untitled) { name in
                await createPlaylist(named: name)
            }
            .presentationBackground(.clear)
        }
        .alert(String(localized: "Couldn't make the playlist.", comment: "The server refused a new playlist of songs, or didn't answer"),
               isPresented: $playlistFailed) {}
    }

    private var header: some View {
        HStack(alignment: .bottom, spacing: 24) {
            ShelfHeader(title: library.displayTitle,
                        eyebrow: total.map(counted) ?? String(localized: "Music", comment: "Eyebrow above a music library's name"),
                        accent: Theme.palette[3 % Theme.palette.count])
            Spacer(minLength: 0)
            // On a phone the order is chosen up here: the row of kinds below
            // fills the screen's width.
            if Theme.isPhone, !tab.sorts.isEmpty {
                sortControl
            }
            Button(action: shuffleAll) {
                Label(String(localized: "Shuffle All", comment: "Plays a whole music library in no order"), systemImage: "shuffle")
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(GradientButtonStyle())
        }
    }

    private var tabs: some View {
        HStack(spacing: 12) {
            ForEach(MusicTab.allCases) { choice in
                Button {
                    guard choice != tab else { return }
                    tab = choice
                    sort = choice.sorts.first ?? .title
                    UserDefaults.standard.set(choice.rawValue, forKey: Self.tabKey(library.id))
                } label: {
                    Text(choice.title)
                }
                .buttonStyle(.pill(selected: tab == choice))
            }
            Spacer(minLength: 0)
            if !Theme.isPhone, !tab.sorts.isEmpty {
                sortControl
            }
        }
        .scrollsSideways(Theme.isPhone)
    }

    /// "6 albums", "30 songs".
    private func counted(_ count: Int) -> String {
        switch tab {
        case .albums: library.countText(count)
        case .artists: String(localized: "\(count) artists", comment: "How many artists a music library has")
        case .songs: String(localized: "\(count) songs", comment: "How many songs a music library has")
        case .genres: String(localized: "\(count) genres", comment: "How many kinds of music a music library has")
        case .playlists: String(localized: "\(count) playlists", comment: "How many playlists of songs the server has")
        case .favorites: String(localized: "\(count) favourites", comment: "How many songs, albums and artists are marked favourite in a music library")
        }
    }

    @ViewBuilder
    private var sortControl: some View {
        #if os(tvOS)
        // Each press, the next order.
        Button {
            let all = tab.sorts
            sort = all[((all.firstIndex(of: sort) ?? 0) + 1) % all.count]
        } label: {
            Label(sort.title, systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(.chip(active: false))
        #else
        Menu {
            Picker(String(localized: "Sort"), selection: $sort) {
                ForEach(tab.sorts, id: \.self) { Text($0.title).tag($0) }
            }
        } label: {
            Group {
                if Theme.isPhone {
                    Image(systemName: "arrow.up.arrow.down")
                        .frame(width: 40, height: 40)
                } else {
                    Label(sort.title, systemImage: "arrow.up.arrow.down")
                        .padding(.horizontal, CGFloat(16).scaled)
                        .padding(.vertical, CGFloat(9).scaled)
                }
            }
            .font(.app(18, .semibold))
            .background(.white.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.14), lineWidth: 1))
        }
        .tint(.white)
        .accessibilityLabel(String(localized: "Sort by \(sort.title)", comment: "Music library: the order it's listed in"))
        #endif
    }

    @ViewBuilder
    private var content: some View {
        if !loaded {
            ProgressView()
                .frame(maxWidth: .infinity, minHeight: 300)
                .focusable()
        } else if tab == .playlists {
            // Room to make one, even with none yet.
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.isPhone ? 20 : 44) {
                NewPlaylistCard { namingPlaylist = true }
                // Named in its identity: items compare by id alone, and a
                // playlist renamed kept its old name on its card.
                ForEach(items) { AlbumCard(item: $0).id($0.id + "|" + ($0.name ?? "")) }
            }
        } else if tab == .favorites {
            favorites
        } else if items.isEmpty {
            Text("Nothing here yet.")
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 40)
        } else if tab == .songs {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { place, song in
                    TrackRow(song: song, showsArtist: true, showsAlbum: true) {
                        play(from: place)
                    }
                    .onAppear { more(after: place) }
                }
            }
        } else if tab == .genres {
            LazyVGrid(columns: genreColumns, alignment: .leading, spacing: Theme.isPhone ? 16 : 40) {
                ForEach(Array(items.enumerated()), id: \.element.id) { place, genre in
                    GenreCard(genre: genre, library: library, place: place)
                }
            }
        } else {
            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.isPhone ? 20 : 44) {
                ForEach(Array(items.enumerated()), id: \.element.id) { place, item in
                    Group {
                        if tab == .artists {
                            ArtistCard(item: item)
                        } else {
                            AlbumCard(item: item)
                        }
                    }
                    .onAppear { more(after: place) }
                }
            }
        }
    }

    private var genreColumns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.isPhone ? 150 : Theme.landscapeWidth * 0.8), spacing: Theme.isPhone ? 14 : 36, alignment: .top)]
    }

    /// The songs, albums and artists marked favourite: the albums and
    /// artists in rows, the songs listed under them to play.
    @ViewBuilder
    private var favorites: some View {
        if items.isEmpty, favoriteAlbums.isEmpty, favoriteArtists.isEmpty {
            Text("Nothing marked yet. A song, an album or an artist is made a favourite from its long-press menu, or with its star.",
                 comment: "Music library, Favourites, with none")
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 40)
                .focusable()
        } else {
            VStack(alignment: .leading, spacing: 30) {
                if !favoriteAlbums.isEmpty {
                    Shelf(title: String(localized: "Albums", comment: "Music library: its albums"), accent: Theme.palette[0]) {
                        ForEach(favoriteAlbums) { AlbumCard(item: $0, width: Theme.posterWidth) }
                    }
                }
                if !favoriteArtists.isEmpty {
                    Shelf(title: String(localized: "Artists", comment: "Music library: who made its albums"), accent: Theme.palette[2]) {
                        ForEach(favoriteArtists) { ArtistCard(item: $0, width: Theme.posterWidth) }
                    }
                }
                if !items.isEmpty {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .bottom, spacing: 18) {
                            ShelfHeader(title: String(localized: "Songs", comment: "Music library: every song in it"),
                                        accent: Theme.palette[1])
                            Spacer(minLength: 0)
                            Button { play(from: 0) } label: {
                                Label(String(localized: "Play"), systemImage: "play.fill")
                            }
                            .buttonStyle(.pill(selected: false))
                            Button { play(from: 0, shuffled: true) } label: {
                                Label(String(localized: "Shuffle"), systemImage: "shuffle")
                            }
                            .buttonStyle(.pill(selected: false))
                        }
                        .tvFocusSection()
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(items.enumerated()), id: \.element.id) { place, song in
                                TrackRow(song: song, showsArtist: true, showsAlbum: true) {
                                    play(from: place)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func shuffleAll() {
        guard let client = app.client else { return }
        let library = library
        MusicPlayer.shared.play(source: library.displayTitle, shuffled: true, client: client) {
            try await client.shuffledSongs(in: library.id, limit: 300)
        }
    }

    /// The songs listed, from the one chosen; as many as have been fetched.
    private func play(from place: Int, shuffled: Bool = false) {
        guard let client = app.client, !items.isEmpty else { return }
        let source = tab == .favorites ? MusicTab.favorites.title : library.displayTitle
        MusicPlayer.shared.play(items, from: place, shuffled: shuffled, source: source, client: client)
    }

    private func more(after place: Int) {
        guard place >= items.count - 12, !loadingMore, let total, items.count < total else { return }
        loadingMore = true
        Task { await load(fresh: false) }
    }

    private func createPlaylist(named typed: String) async {
        guard let client = app.client else { return }
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await client.createPlaylist(named: name.isEmpty ? PlaylistPicker.untitled : name, songs: [])
        } catch {
            playlistFailed = true
            return
        }
        app.collectionsChanged()
        NotificationCenter.default.post(name: .songPlaylistsChanged, object: nil)
    }

    /// `fresh` starts the list again; otherwise it's the next page, or for
    /// the lists that come whole (genres, playlists, favourites), the same
    /// list asked again without the spinner.
    private func load(fresh: Bool) async {
        // A page asked for by `more` is marked as loading before this starts.
        defer { if !fresh { loadingMore = false } }
        guard let client = app.client else { return }
        let asked = (tab, sort)
        let askedAt = Date()
        switch tab {
        case .playlists, .genres:
            if fresh { loaded = false }
            let found = (try? await tab == .playlists ? client.songPlaylists() : client.musicGenres(in: library.id)) ?? []
            guard asked == (tab, sort) else { return }
            if !fresh { app.holdMenuFocus() }
            items = found
            total = found.count
            loaded = true
            return
        case .favorites:
            if fresh { loaded = false }
            async let albums = try? client.favoriteMusic(.albums, in: library.id)
            async let artists = try? client.favoriteMusic(.artists, in: library.id)
            let songs = (try? await client.favoriteMusic(.songs, in: library.id)) ?? []
            let (foundAlbums, foundArtists) = (await albums ?? [], await artists ?? [])
            guard asked == (tab, sort) else { return }
            if !fresh { app.holdMenuFocus() }
            favoriteAlbums = foundAlbums
            favoriteArtists = foundArtists
            items = songs
            MusicFavorites.shared.heard(songs + foundAlbums + foundArtists, askedAt: askedAt)
            total = songs.count + foundAlbums.count + foundArtists.count
            loaded = true
            return
        case .albums, .artists, .songs:
            break
        }
        guard let kind = tab.kind else { return }
        if fresh { loaded = false } else { loadingMore = true }
        defer { loadingMore = false }
        let order = sort.api(for: tab)
        let start = fresh ? 0 : items.count
        guard let result = try? await client.music(kind, in: library.id, startIndex: start, limit: Self.page,
                                                   sortBy: order.by, sortOrder: order.order),
              asked == (tab, sort) else {
            if fresh { loaded = true }
            return
        }
        if fresh {
            items = result.items
        } else {
            let have = Set(items.map(\.id))
            items += result.items.filter { !have.contains($0.id) }
        }
        MusicFavorites.shared.heard(result.items, askedAt: askedAt)
        total = result.totalRecordCount ?? items.count
        loaded = true
    }
}

// MARK: - An album or a playlist

/// An album, or a playlist of songs: its cover and what it is beside its
/// songs on a television or a tablet, above them on a phone. A playlist this
/// account may change has its songs moved and taken out from their
/// long-press menus (on a phone or a tablet, in Edit too), and is renamed or
/// deleted with its own buttons.
struct AlbumView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.sectionNavigator) private var navigator
    @Environment(\.isNarrow) private var narrowClass
    @Environment(\.dismiss) private var dismiss
    /// The page's width, for a tablet held upright.
    @State private var width: CGFloat = 0
    let albumId: String
    var name: String? = nil
    var initial: BaseItem? = nil

    @State private var album: BaseItem?
    @State private var rows: [PlaylistRow] = []
    private var tracks: [BaseItem] { rows.map(\.song) }
    @State private var loaded = false
    @FocusState private var playFocused: Bool
    /// Whether this account may change the playlist.
    @State private var editable = false
    @State private var panel: Panel?
    @State private var deleting = false
    @State private var problem: String?
    /// The name given it here, since it was fetched.
    @State private var renamed: String?
    #if !os(tvOS)
    @State private var editing = false
    #else
    /// The song being carried along the playlist, by its place in it, and
    /// where it was picked up from: the Apple TV's way of reordering one.
    @State private var moving: (key: String, from: Int)?
    /// Counts each step of it, for the list to keep the song in view.
    @State private var moveSteps = 0
    @FocusState private var rowFocus: String?
    #endif

    /// The panels the page opens over itself, one at a time.
    private enum Panel: Identifiable {
        case rename
        case add(PlaylistAddition)

        var id: String {
            switch self {
            case .rename: "rename"
            case .add(let addition): addition.id.uuidString
            }
        }
    }

    private var shown: BaseItem? { album ?? initial }
    /// Its name: as renamed here, or as the server has it.
    private var title: String { renamed ?? shown?.displayTitle ?? name ?? "" }

    #if os(tvOS)
    private let coverSide: CGFloat = 400
    #else
    private var coverSide: CGFloat { narrow ? (Theme.isPhone ? 260 : 340) : 320 }
    #endif

    /// The cover above the songs: on a phone, and on a tablet without the
    /// width for the songs beside it (one held upright).
    private var narrow: Bool {
        #if !os(tvOS)
        narrowClass || (width > 0 && width < 900)
        #else
        false
        #endif
    }

    private var isMoving: Bool {
        #if os(tvOS)
        moving != nil
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if narrow {
                ScrollView {
                    VStack(spacing: 18) {
                        cover
                        about(centred: true)
                        buttons
                        trackList
                    }
                    .padding(.horizontal, Theme.pageMargin)
                    .padding(.vertical, 20)
                }
            } else {
                HStack(alignment: .top, spacing: CGFloat(56)) {
                    VStack(alignment: .leading, spacing: 22) {
                        cover
                        about(centred: false)
                        buttons
                    }
                    .frame(width: coverSide)
                    // Nothing here while a song is carried along the list:
                    // a press left would take it out of the list.
                    .disabled(isMoving)
                    .tvFocusSection()
                    ScrollViewReader { proxy in
                        ScrollView {
                            trackList
                                .padding(.vertical, 30)
                                .padding(.horizontal, 10)
                        }
                        #if os(tvOS)
                        .onChange(of: moveSteps) { _, _ in
                            guard let key = moving?.key else { return }
                            withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(key) }
                        }
                        #endif
                    }
                    .overlay(alignment: .top) { moveHint }
                    .tvFocusSection()
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.top, 48)
                #if os(tvOS)
                .defaultFocus($playFocused, true)
                #endif
            }
        }
        .pageSides()
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .task(id: albumId) { await load() }
        // Songs put in this playlist from elsewhere (Now Playing's menu, say).
        .onReceive(NotificationCenter.default.publisher(for: .songPlaylistsChanged)) { note in
            if note.object as? String == albumId { Task { await load() } }
        }
        #if os(tvOS)
        // The song carried along the list lost focus (to the menu): it's put
        // down where it is.
        .background { FocusWatcher(focus: $rowFocus) { _, now in if let key = moving?.key, now != key { finishMove() } } }
        #endif
        .fullScreenCover(item: $panel) { panel in
            switch panel {
            case .rename:
                TextEntryPanel(title: String(localized: "Rename Playlist", comment: "Title of the panel renaming a playlist of songs"),
                               message: String(localized: "Its new name.", comment: "Asks for a playlist's new name"),
                               placeholder: title, initial: title) { name in
                    await rename(to: name)
                }
                .presentationBackground(.clear)
            case .add(let addition):
                PlaylistPicker(addition: addition)
                    .presentationBackground(.clear)
            }
        }
        #if !os(tvOS)
        .sheet(isPresented: $editing) {
            PlaylistEditor(name: title, rows: $rows, move: move(from:to:), remove: remove)
        }
        #endif
        // Asked twice: there's no having it back.
        .confirmationDialog(title, isPresented: $deleting, titleVisibility: .visible) {
            Button(String(localized: "Delete Playlist", comment: "Deletes a playlist of songs from the server"), role: .destructive) {
                deletePlaylist()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The playlist is deleted from your server. Its songs stay in your library.",
                 comment: "Asked before a playlist of songs is deleted")
        }
        .alert(problem ?? "", isPresented: $problem.isPresent()) {}
    }

    private var cover: some View {
        Group {
            if let shown {
                MusicArt(item: shown, maxWidth: 800)
            } else {
                Theme.surface
            }
        }
        .frame(width: coverSide, height: coverSide)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
    }

    private func about(centred: Bool) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: 8) {
            Text(isPlaylist ? String(localized: "PLAYLIST", comment: "Above a playlist's name, in capitals")
                            : String(localized: "ALBUM", comment: "Above an album's name, in capitals"))
                .font(.app(13, .heavy))
                .kerning(1.6)
                .foregroundStyle(Theme.primary.1)
            Text(title)
                .font(.app(Theme.isPhone ? 30 : 34, .bold))
                .multilineTextAlignment(centred ? .center : .leading)
                .lineLimit(3)
            if let artist = shown?.leadArtist, let artistName = shown?.albumArtist ?? artist.name {
                Button {
                    navigator.showMusic(MusicRoute(kind: .artist, id: artist.id, name: artist.name))
                } label: {
                    Text(artistName)
                }
                .buttonStyle(.studio)
                .padding(.horizontal, -12)
            }
            if let facts {
                Text(facts)
                    .font(.app(16))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(centred ? .center : .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
    }

    private var isPlaylist: Bool { (shown ?? initial)?.type == "Playlist" }

    /// "2022 · Pop · 6 songs, 24 min".
    private var facts: String? {
        var parts: [String] = []
        if !isPlaylist, let year = shown?.productionYear { parts.append(String(year)) }
        if let genre = shown?.genres?.first { parts.append(genre) }
        if loaded {
            let songs = String(localized: "\(tracks.count) songs", comment: "How many songs a music library has")
            let seconds = tracks.compactMap(\.runTimeTicks).reduce(0, +) / 10_000_000
            if tracks.isEmpty {
                // An empty playlist isn't a minute long.
                parts.append(songs)
            } else {
                let minutes = max(1, Int(seconds / 60))
                let length = minutes >= 60 ? String(localized: "\(minutes / 60) hr \(minutes % 60) min", comment: "An album's length")
                                           : String(localized: "\(minutes) min", comment: "An album's length")
                parts.append(songs + ", " + length)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private var buttons: some View {
        VStack(alignment: narrow ? .center : .leading, spacing: 16) {
            HStack(spacing: 14) {
                Button { play(from: 0, shuffled: false) } label: {
                    Label(String(localized: "Play"), systemImage: "play.fill")
                        .frame(minWidth: CGFloat(narrow ? 110 : 120).scaled)
                }
                .buttonStyle(GradientButtonStyle())
                .focused($playFocused)
                Button { play(from: 0, shuffled: true) } label: {
                    Label(String(localized: "Shuffle"), systemImage: "shuffle")
                }
                .buttonStyle(.pill(selected: false))
            }
            HStack(spacing: 14) {
                #if !os(tvOS)
                // Kept on the device, to play without the server.
                if let shown {
                    DownloadGroupButton(id: albumId, kind: isPlaylist ? .playlist : .album, name: renamed ?? shown.displayTitle,
                                        byLine: isPlaylist ? nil : shown.byLine, pageId: albumId, items: tracks, art: shown)
                }
                #endif
                if !isPlaylist {
                    Button(action: instantMix) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.action(active: false))
                    .accessibilityLabel(String(localized: "Instant Mix", comment: "Plays songs like this one, chosen by the server"))
                }
                if let shown {
                    if !isPlaylist { MusicFavoriteButton(item: shown) }
                    Button {
                        let songs = tracks
                        panel = .add(PlaylistAddition(item: shown) { songs })
                    } label: {
                        Image(systemName: "text.badge.plus")
                    }
                    .buttonStyle(.action(active: false))
                    .disabled(tracks.isEmpty)
                    .accessibilityLabel(String(localized: "Add to Playlist", comment: "Puts songs in a playlist, chosen next"))
                }
                if isPlaylist, editable {
                    #if !os(tvOS)
                    Button { editing = true } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.action(active: false))
                    .disabled(tracks.isEmpty)
                    .accessibilityLabel(String(localized: "Edit Playlist", comment: "Opens a playlist's songs to reorder and remove"))
                    #endif
                    Button { panel = .rename } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(.action(active: false))
                    .accessibilityLabel(String(localized: "Rename Playlist", comment: "Title of the panel renaming a playlist of songs"))
                    Button { deleting = true } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.action(active: false))
                    .accessibilityLabel(String(localized: "Delete Playlist", comment: "Deletes a playlist of songs from the server"))
                }
            }
        }
    }

    @ViewBuilder
    private var trackList: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else if rows.isEmpty, isPlaylist {
            Text("Nothing in this playlist yet. Songs go in from their long-press menu: Add to Playlist.",
                 comment: "An empty playlist of songs")
                .foregroundStyle(Theme.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 20)
                .focusable()
        } else {
            let discs = Set(tracks.compactMap(\.parentIndexNumber))
            let compilation = tracks.contains { $0.byLine != shown?.albumArtist }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { place, row in
                    if !isPlaylist, discs.count > 1, let disc = row.song.parentIndexNumber,
                       place == 0 || rows[place - 1].song.parentIndexNumber != disc {
                        Text(String(localized: "Disc \(disc)", comment: "Heads one disc's songs on an album of several"))
                            .font(.app(15, .heavy))
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, place == 0 ? 0 : 18)
                            .padding(.leading, 14)
                            .padding(.bottom, 4)
                    }
                    line(row, at: place, compilation: compilation)
                }
            }
        }
    }

    @ViewBuilder
    private func line(_ row: PlaylistRow, at place: Int, compilation: Bool) -> some View {
        let song = row.song
        #if os(tvOS)
        let carried = moving?.key == row.key
        TrackRow(song: song, number: isPlaylist ? nil : (song.indexNumber ?? place + 1),
                 showsArtist: isPlaylist || compilation, showsAlbum: isPlaylist, moving: carried,
                 menuActions: { playlistActions(for: row) }) {
            if moving != nil { finishMove() } else { play(from: place, shuffled: false) }
        }
        .focused($rowFocus, equals: row.key)
        // While one is carried, the others are where it goes, not places to go.
        .disabled(moving != nil && !carried)
        .onMoveCommand(perform: carried ? { step($0) } : nil)
        .onExitCommand(perform: carried ? { cancelMove() } : nil)
        .id(row.key)
        #else
        TrackRow(song: song, number: isPlaylist ? nil : (song.indexNumber ?? place + 1),
                 showsArtist: isPlaylist || compilation, showsAlbum: isPlaylist,
                 menuActions: { playlistActions(for: row) }) {
            play(from: place, shuffled: false)
        }
        #endif
    }

    /// What carrying a song along the list does, over the list while it's carried.
    @ViewBuilder
    private var moveHint: some View {
        #if os(tvOS)
        if moving != nil {
            Text("Up and down move it. Select puts it there; Back puts it back.",
                 comment: "Apple TV, moving a song along a playlist: how")
                .font(.app(17, .semibold))
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
                .background(.ultraThinMaterial, in: Capsule())
                .transition(.opacity)
                .allowsHitTesting(false)
        }
        #endif
    }

    /// A playlist's own rows for a song's long-press menu: moving it (on the
    /// Apple TV; Edit does it on a touch screen) and taking it out.
    private func playlistActions(for row: PlaylistRow) -> [ItemMenuAction] {
        guard isPlaylist, editable, row.song.playlistItemId != nil else { return [] }
        var actions: [ItemMenuAction] = []
        #if os(tvOS)
        if rows.count > 1 {
            actions.append(.init(title: String(localized: "Move", comment: "Playlist: picks a song up, to move it along the list with up and down"),
                                 icon: "arrow.up.arrow.down") { startMove(row) })
        }
        #endif
        actions.append(.init(title: String(localized: "Remove from Playlist", comment: "Takes a song out of a playlist; the song stays in the library"),
                             icon: "minus.circle", destructive: true) { remove(row) })
        return actions
    }

    private func load() async {
        guard let client = app.client else { return }
        let askedAt = Date()
        // What it is decides how its songs are asked for; known from the
        // card that opened it, or else asked first.
        var item = initial ?? album
        // Asked now, when what came with it was a card's listing; once, if
        // nothing came with it.
        let fetched = item == nil ? try? await client.item(id: albumId) : nil
        if let fetched { item = fetched }
        let playlist = item?.type == "Playlist"
        async let full: BaseItem? = fetched == nil ? (try? await client.item(id: albumId)) : fetched
        async let permitted = playlist ? client.canEditPlaylist(albumId) : false
        let found = (try? await client.tracks(of: albumId, playlist: playlist)) ?? []
        let fresh = await full
        album = fresh ?? item
        MusicFavorites.shared.heard(found + [fresh].compactMap { $0 }, askedAt: askedAt)
        if loaded { app.holdMenuFocus() }
        rows = found.filter(\.isSong).map { PlaylistRow(song: $0) }
        loaded = true
        editable = await permitted
    }

    private func play(from place: Int, shuffled: Bool) {
        guard let client = app.client, !rows.isEmpty else { return }
        MusicPlayer.shared.play(tracks, from: place, shuffled: shuffled, source: title, client: client)
    }

    private func instantMix() {
        guard let client = app.client else { return }
        let id = albumId
        MusicPlayer.shared.play(source: String(localized: "Instant Mix"), client: client) {
            try await client.instantMix(from: id, limit: 200)
        }
    }

    // MARK: Changing a playlist

    /// Lists elsewhere (the library's playlists, their counts) ask again.
    private func changed() {
        NotificationCenter.default.post(name: .songPlaylistsChanged, object: nil)
    }

    private func failed() {
        problem = String(localized: "Couldn't change the playlist.", comment: "The server refused a change to a playlist of songs, or didn't answer")
    }

    /// Whether the song is in the playlist more than once. The server names
    /// a song's places in a playlist by the song, so it can't be told which
    /// of them is meant: after a change to one, the list is asked again, to
    /// show what the server did.
    private func isTwice(_ entry: String) -> Bool {
        rows.filter { $0.song.playlistItemId == entry }.count > 1
    }

    private func remove(_ row: PlaylistRow) {
        guard let entry = row.song.playlistItemId, let client = app.client else { return }
        let before = rows
        let twice = isTwice(entry)
        // Focus was on the song going: kept on the page, on the song after
        // it (or, the last going, the one before).
        app.holdMenuFocus()
        #if os(tvOS)
        if let at = rows.firstIndex(where: { $0.id == row.id }) {
            let next = rows.indices.contains(at + 1) ? rows[at + 1] : rows.indices.contains(at - 1) ? rows[at - 1] : nil
            if let next { Task { @MainActor in rowFocus = next.key } }
        }
        #endif
        withAnimation(.easeOut(duration: 0.2)) { rows.removeAll { $0.id == row.id } }
        Task {
            do {
                try await client.removeFromPlaylist(albumId, entries: [entry])
                changed()
                if twice { await load() }
            } catch {
                rows = before
                failed()
            }
        }
    }

    /// Moves a song from one place to another (each counted from 0, the
    /// second once it's out of the list), and tells the server.
    private func move(from: Int, to: Int) {
        guard from != to, rows.indices.contains(from), rows.indices.contains(to),
              let entry = rows[from].song.playlistItemId, let client = app.client else { return }
        let twice = isTwice(entry)
        rows.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        send(entry, to: to, again: twice, client: client)
    }

    private func send(_ entry: String, to place: Int, again: Bool, client: any MediaServer) {
        Task {
            do {
                try await client.movePlaylistEntry(albumId, entry: entry, to: place)
                changed()
                if again { await load() }
            } catch {
                failed()
                await load()
            }
        }
    }

    #if os(tvOS)
    private func startMove(_ row: PlaylistRow) {
        guard let place = rows.firstIndex(where: { $0.id == row.id }) else { return }
        withAnimation(.easeOut(duration: 0.2)) { moving = (row.key, place) }
        rowFocus = row.key
    }

    private func step(_ direction: MoveCommandDirection) {
        guard let key = moving?.key, let at = rows.firstIndex(where: { $0.key == key }) else { return }
        let to = switch direction {
        case .up: at - 1
        case .down: at + 1
        default: at
        }
        guard to != at, rows.indices.contains(to) else { return }
        withAnimation(.easeOut(duration: 0.15)) { rows.swapAt(at, to) }
        moveSteps += 1
    }

    /// Put down where it is, and the server told.
    private func finishMove() {
        guard let carried = moving else { return }
        withAnimation(.easeOut(duration: 0.2)) { moving = nil }
        guard let at = rows.firstIndex(where: { $0.key == carried.key }), at != carried.from,
              let entry = rows[at].song.playlistItemId, let client = app.client else { return }
        send(entry, to: at, again: isTwice(entry), client: client)
    }

    /// Put back where it was picked up.
    private func cancelMove() {
        guard let carried = moving else { return }
        withAnimation(.easeOut(duration: 0.2)) {
            if let at = rows.firstIndex(where: { $0.key == carried.key }), at != carried.from {
                rows.move(fromOffsets: IndexSet(integer: at), toOffset: carried.from > at ? carried.from + 1 : carried.from)
            }
            moving = nil
        }
    }
    #endif

    private func rename(to typed: String) async {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != title, let client = app.client else { return }
        do {
            try await client.renamePlaylist(albumId, to: name)
            // Said apart: the item fetched again is "equal" to the one
            // shown (items compare by id), and the page wouldn't redraw.
            renamed = name
            changed()
        } catch {
            failed()
        }
    }

    private func deletePlaylist() {
        guard let client = app.client else { return }
        Task {
            do {
                try await client.deleteItem(albumId)
                changed()
                // Gone from the Collections section too, and with the last
                // of them, its row from the menu.
                app.deleted([albumId])
                app.collectionsChanged()
                app.holdMenuFocus()
                dismiss()
            } catch {
                problem = String(localized: "Couldn't delete the playlist.", comment: "The server refused to delete a playlist of songs, or didn't answer")
            }
        }
    }
}

// MARK: - An artist

/// Someone's songs played most, their albums, the ones they're on, and
/// others like them; what the server knows of them, and their songs to play.
struct ArtistView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.isNarrow) private var narrow
    @Environment(\.sectionNavigator) private var navigator
    let artistId: String
    var name: String? = nil
    var initial: BaseItem? = nil

    @State private var artist: BaseItem?
    @State private var albums: [BaseItem] = []
    @State private var appearsOn: [BaseItem] = []
    @State private var topSongs: [BaseItem] = []
    /// Whether any of them has been played: they're the top songs then, and
    /// otherwise only the first.
    @State private var anyPlayed = false
    @State private var similar: [BaseItem] = []
    @State private var loaded = false

    /// How many of their songs the page lists.
    private static let topCount = 5

    private var shown: BaseItem? { artist ?? initial }
    private var displayName: String { shown?.displayTitle ?? name ?? "" }
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.posterWidth), spacing: Theme.isPhone ? 16 : 36, alignment: .top)]
    }
    #if os(tvOS)
    private let photoSide: CGFloat = 300
    #else
    private var photoSide: CGFloat { narrow ? 180 : 240 }
    #endif

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 36) {
                header
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                } else {
                    if !topSongs.isEmpty { songs }
                    if !albums.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            ShelfHeader(title: String(localized: "Albums", comment: "Music library: its albums"),
                                        accent: Theme.palette[0])
                            LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.isPhone ? 20 : 44) {
                                ForEach(albums) { album in
                                    AlbumCard(item: album, note: album.productionYear.map(String.init) ?? "")
                                }
                            }
                        }
                        .tvFocusSection()
                    }
                    if !appearsOn.isEmpty {
                        Shelf(title: String(localized: "Appears On", comment: "An artist's page: albums of others they sing on"),
                              accent: Theme.palette[2]) {
                            ForEach(appearsOn) { album in
                                AlbumCard(item: album, width: Theme.posterWidth)
                            }
                        }
                        // Regions, so down lands in a short row from anywhere above it.
                        .tvFocusSection()
                    }
                    if !similar.isEmpty {
                        Shelf(title: String(localized: "Similar Artists", comment: "An artist's page: others like them"),
                              accent: Theme.palette[3 % Theme.palette.count]) {
                            ForEach(similar) { other in
                                ArtistCard(item: other, width: Theme.posterWidth)
                            }
                        }
                        .tvFocusSection()
                    }
                    if albums.isEmpty && appearsOn.isEmpty && topSongs.isEmpty {
                        Text("Nothing here yet.")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, Theme.isPhone ? 20 : 48)
        }
        .pageSides()
        .task(id: artistId) { await load() }
    }

    @ViewBuilder
    private var header: some View {
        let layout = narrow ? AnyLayout(VStackLayout(spacing: 18)) : AnyLayout(HStackLayout(alignment: .center, spacing: 40))
        layout {
            Group {
                if let shown {
                    MusicArt(item: shown, maxWidth: 600)
                } else {
                    Theme.surface
                }
            }
            .frame(width: photoSide, height: photoSide)
            .clipShape(Circle())
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            VStack(alignment: narrow ? .center : .leading, spacing: 14) {
                Text(String(localized: "ARTIST", comment: "Above an artist's name, in capitals"))
                    .font(.app(13, .heavy))
                    .kerning(1.6)
                    .foregroundStyle(Theme.primary.1)
                Text(displayName)
                    .font(.app(Theme.isPhone ? 32 : 44, .bold))
                    .lineLimit(2)
                    .multilineTextAlignment(narrow ? .center : .leading)
                if let genres = shown?.genres, !genres.isEmpty {
                    Text(genres.prefix(3).joined(separator: " · "))
                        .font(.app(17))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let bio = biography {
                    // The first paragraph, a few lines of it; click for the rest.
                    ExpandableText(text: bio.first, full: bio.full, lines: 3, maxWidth: 900)
                }
                HStack(spacing: 14) {
                    Button { play(shuffled: false) } label: {
                        Label(String(localized: "Play"), systemImage: "play.fill")
                    }
                    .buttonStyle(GradientButtonStyle())
                    Button { play(shuffled: true) } label: {
                        Label(String(localized: "Shuffle"), systemImage: "shuffle")
                    }
                    .buttonStyle(.pill(selected: false))
                    Button(action: instantMix) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.action(active: false))
                    .accessibilityLabel(String(localized: "Instant Mix", comment: "Plays songs like this one, chosen by the server"))
                    if let shown { MusicFavoriteButton(item: shown) }
                }
            }
            .frame(maxWidth: narrow ? .infinity : nil, alignment: narrow ? .center : .leading)
        }
        .frame(maxWidth: .infinity, alignment: narrow ? .center : .leading)
        .tvFocusSection()
    }

    /// The first paragraph of what the server knows of them, and the whole.
    private var biography: (first: String, full: String)? {
        guard let full = shown?.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !full.isEmpty else { return nil }
        let first = full.components(separatedBy: "\n").first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? full
        return (first.trimmingCharacters(in: .whitespaces), full)
    }

    /// Their songs played most (or, none played yet, their first), and the
    /// way to all of them.
    private var songs: some View {
        VStack(alignment: .leading, spacing: 12) {
            // The way to all of them beside the heading, above the songs, where
            // up from the first of them finds it.
            HStack(alignment: .bottom, spacing: 24) {
                ShelfHeader(title: anyPlayed ? String(localized: "Top Songs", comment: "An artist's page: their songs played most")
                                             : String(localized: "Songs", comment: "Music library: every song in it"),
                            accent: Theme.palette[1])
                    .fixedSize()
                Button {
                    navigator.showMusic(MusicRoute(kind: .artistSongs, id: artistId, name: displayName))
                } label: {
                    Label(String(localized: "All Songs", comment: "Above a page of every song an artist sings on"), systemImage: "chevron.right")
                        .labelStyle(TrailingIconLabelStyle())
                }
                .buttonStyle(.pill(selected: false))
                Spacer(minLength: 0)
            }
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(Array(topSongs.enumerated()), id: \.element.id) { place, song in
                    TrackRow(song: song, showsArtist: false, showsAlbum: true) {
                        playTop(from: place)
                    }
                }
            }
            .frame(maxWidth: Theme.isPhone ? .infinity : 1100, alignment: .leading)
        }
        // One region, the page's width: down from the buttons above lands on
        // the first song. With its heading a region of its own, it landed on
        // All Songs, the heading's one button, and the songs were skipped.
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSection()
    }

    private func load() async {
        guard let client = app.client else { return }
        let askedAt = Date()
        async let full = try? client.item(id: artistId)
        async let theirs = try? client.albums(by: artistId)
        async let others = try? client.albums(featuring: artistId)
        async let most = try? client.mostPlayedSongs(by: artistId, limit: Self.topCount)
        async let first = try? client.songs(by: artistId, shuffled: false, limit: 30)
        async let like = try? client.similarArtists(to: artistId, limit: 16)
        artist = await full
        albums = await theirs ?? []
        appearsOn = await others ?? []
        // The ones played most, made up to five with the rest in order.
        let played = await most ?? []
        var top = played
        for song in await first ?? [] where top.count < Self.topCount && !top.contains(song) { top.append(song) }
        topSongs = top
        anyPlayed = !played.isEmpty
        // Not themselves under another name ("The Geese feat. Gander").
        let own = (artist?.name ?? name ?? "").lowercased()
        similar = (await like ?? []).filter { own.isEmpty || !($0.name ?? "").lowercased().contains(own) }
        MusicFavorites.shared.heard(top + albums + appearsOn + [artist].compactMap { $0 }, askedAt: askedAt)
        loaded = true
    }

    private func play(shuffled: Bool) {
        guard let client = app.client else { return }
        let id = artistId
        MusicPlayer.shared.play(source: displayName, shuffled: shuffled, client: client) {
            try await client.songs(by: id, shuffled: false, limit: 1000)
        }
    }

    private func playTop(from place: Int) {
        guard let client = app.client, !topSongs.isEmpty else { return }
        MusicPlayer.shared.play(topSongs, from: place, source: displayName, client: client)
    }

    private func instantMix() {
        guard let client = app.client else { return }
        let id = artistId
        MusicPlayer.shared.play(source: String(localized: "Instant Mix"), client: client) {
            try await client.instantMix(from: id, limit: 200)
        }
    }
}

/// A label with its icon after its words: "All Songs ›".
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.title
            configuration.icon
        }
    }
}
