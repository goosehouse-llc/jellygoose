import SwiftUI

/// Films and shows, then music (artists, albums, songs), then what's on
/// television, then the collections and the people the words turn up, a
/// row of each. Not episodes: one is found
/// through its show, which is where a title someone remembers leads anyway,
/// and a show's worth of them for every word typed buried what was being
/// looked for. The listings likewise: a programme once, however often it's on.
struct SearchView: View {
    @EnvironmentObject var app: AppState
    @Binding var path: NavigationPath
    @State private var query = ""
    @State private var results: [BaseItem] = []
    @State private var collections: [BaseItem] = []
    @State private var people: [Person] = []
    /// What the words turn up in the music libraries, where there are any.
    @State private var artists: [BaseItem] = []
    @State private var albums: [BaseItem] = []
    @State private var songs: [BaseItem] = []
    /// And in the libraries of audiobooks, as books.
    @State private var books: [Audiobook] = []
    @State private var searchTask: Task<Void, Never>?
    /// The programmes and channels the words turn up, where there's television.
    @StateObject private var listings = LiveSearch()
    /// A channel chosen among them, filling the screen.
    @State private var watching: BaseItem?

    private let columns = [GridItem(.adaptive(minimum: Theme.posterWidth), spacing: 24)]

    private var nothingFound: Bool {
        results.isEmpty && collections.isEmpty && people.isEmpty && listings.shows.isEmpty && listings.channels.isEmpty
            && artists.isEmpty && albums.isEmpty && songs.isEmpty && books.isEmpty
    }

    private var hasMusic: Bool { app.libraries.contains(where: \.holdsMusic) }
    private var hasBooks: Bool { app.libraries.contains(where: \.holdsBooks) }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                // Nothing is asked for under two characters, so nothing is missing.
                if nothingFound && query.count >= 2 {
                    Text("No results for “\(query)”")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 100)
                } else {
                    VStack(alignment: .leading, spacing: 28) {
                        if !results.isEmpty {
                            LazyVGrid(columns: columns, spacing: 32) {
                                ForEach(results) { PosterNavCard(item: $0) }
                            }
                        }
                        // Each a row the width of the page, so that down from
                        // a short last line of posters still finds it.
                        if !artists.isEmpty {
                            Shelf(title: String(localized: "Artists", comment: "Music library: who made its albums"), accent: Theme.palette[3]) {
                                ForEach(artists) { ArtistCard(item: $0, width: Theme.posterWidth) }
                            }
                            .tvFocusSection()
                        }
                        if !albums.isEmpty {
                            Shelf(title: String(localized: "Albums", comment: "Music library: its albums"), accent: Theme.palette[0]) {
                                ForEach(albums) { AlbumCard(item: $0, width: Theme.posterWidth) }
                            }
                            .tvFocusSection()
                        }
                        if !songs.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                ShelfHeader(title: String(localized: "Songs", comment: "Music library: every song in it"), accent: Theme.palette[2])
                                    .padding(.horizontal, 4)
                                LazyVStack(alignment: .leading, spacing: 2) {
                                    ForEach(Array(songs.enumerated()), id: \.element.id) { place, song in
                                        TrackRow(song: song, showsArtist: true, showsAlbum: true) {
                                            if let client = app.client {
                                                MusicPlayer.shared.play(songs, from: place, source: String(localized: "Search"), client: client)
                                            }
                                        }
                                    }
                                }
                                .frame(maxWidth: 1100, alignment: .leading)
                            }
                            .tvFocusSection()
                        }
                        if !books.isEmpty {
                            Shelf(title: String(localized: "Audiobooks"), accent: Theme.palette[3]) {
                                ForEach(books) { BookCard(book: $0, width: Theme.posterWidth) }
                            }
                            .tvFocusSection()
                        }
                        if !listings.shows.isEmpty {
                            Shelf(title: String(localized: "On TV", comment: "Search: heading over the television programmes the words found in the listings"),
                                  accent: Theme.palette[2]) {
                                ForEach(listings.shows) { LiveShowCard(show: $0) }
                            }
                            .tvFocusSection()
                        }
                        if !listings.channels.isEmpty {
                            Shelf(title: String(localized: "Channels"), accent: Theme.palette[2]) {
                                ForEach(listings.channels) { channel in
                                    LiveNowCard(item: channel) { watching = channel }
                                }
                            }
                            .tvFocusSection()
                        }
                        if !collections.isEmpty {
                            Shelf(title: String(localized: "Collections"), accent: Theme.palette[1]) {
                                ForEach(collections) { SearchCollectionCard(item: $0) }
                            }
                            .tvFocusSection()
                        }
                        if !people.isEmpty {
                            Shelf(title: String(localized: "People", comment: "Heading over the cast and crew a search found"),
                                  accent: Theme.palette[3]) {
                                ForEach(people) { person in
                                    CastCard(person: person) { path.append(person) }
                                }
                            }
                            .tvFocusSection()
                        }
                    }
                    .padding(.horizontal, Theme.pageMargin)
                    .padding(.vertical, 48)
                }
            }
            .pageSides()
            #if os(iOS)
            // Across the top of the page, not tucked into a corner of the bar.
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: prompt)
            #elseif os(macOS)
            // On the page: the Mac's window shows no title bar to hold it.
            .safeAreaInset(edge: .top, spacing: 0) { MacSearchField(text: $query, prompt: prompt) }
            #else
            .searchable(text: $query, prompt: prompt)
            #endif
            .sectionDestinations()
            .navigationDestination(for: LiveShow.self) { show in
                LiveShowPage(search: listings, show: show)
            }
        }
        // Back from the picture to the channel's card, not to the menu.
        .fullScreenCover(item: $watching, onDismiss: { app.holdMenuFocus() }) { channel in
            if let client = app.client { LiveWatchHost(channel: channel, client: client) }
        }
        .sectionNavigation(path: $path, section: "search")
        .onChange(of: query) { _, newValue in
            searchTask?.cancel()
            guard newValue.count >= 2 else {
                results = []
                collections = []
                people = []
                artists = []
                albums = []
                songs = []
                books = []
                listings.clear()
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(350))   // debounce
                guard !Task.isCancelled, let client = app.client else { return }
                // All four asked at once; the titles shown as soon as they
                // come, without waiting on the rows under them.
                async let sets = try? client.searchCollections(newValue)
                async let cast = try? client.searchPeople(newValue)
                async let music = hasMusic ? try? client.searchMusic(newValue) : nil
                async let audiobooks = hasBooks ? await Self.books(matching: newValue, with: client) : []
                // The listings alongside, and in their own time.
                async let television: Void = searchListings(newValue, with: client)
                if let found = try? await client.search(newValue), !Task.isCancelled {
                    results = found
                }
                let (foundSets, foundCast, foundMusic, foundBooks) = await (sets, cast, music, audiobooks)
                guard !Task.isCancelled else { return }
                books = foundBooks
                collections = foundSets ?? []
                people = foundCast ?? []
                artists = foundMusic?.artists ?? []
                albums = foundMusic?.albums ?? []
                songs = foundMusic?.songs ?? []
                await television
            }
        }
        .onChange(of: app.hasLiveTV) { _, has in
            if !has { listings.clear() }
        }
    }

    /// The audiobooks the words turn up, made into books as their library
    /// makes them: the parts of one together, under their folder's name.
    private static func books(matching term: String, with client: any MediaServer) async -> [Audiobook] {
        let files = (try? await client.searchAudiobooks(term)) ?? []
        let inParts = Dictionary(grouping: files.compactMap(\.parentId)) { $0 }.filter { $0.value.count > 1 }
        let folders = inParts.isEmpty ? [] : (try? await client.items(ids: Array(inParts.keys))) ?? []
        return Audiobooks.books(from: files, folders: Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
    }

    private func searchListings(_ term: String, with client: any MediaServer) async {
        if app.hasLiveTV { await listings.search(term, with: client) }
    }

    /// What the box says it looks through.
    private var prompt: Text {
        if hasMusic {
            return app.hasLiveTV ? Text("Movies, shows, music, people and TV…", comment: "Search box prompt, where there's music and television to search too")
                                 : Text("Movies, shows, music and people…", comment: "Search box prompt, where there's music to search too")
        }
        return app.hasLiveTV ? Text("Movies, shows, people and TV…", comment: "Search box prompt, where there's television to search too")
                             : Text("Movies, shows and people…")
    }
}

/// A collection or playlist among the results: its poster and name, through
/// to what's in it. No long-press menu, which is for things that play.
private struct SearchCollectionCard: View {
    let item: BaseItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: item) {
                PosterCardContent(item: item, width: Theme.posterWidth)
            }
            .buttonStyle(.tvCard)
            .accessibilityLabel(item.displayTitle)
            .accessibilityHint("Opens this library")
            Text(item.displayTitle)
                .font(.app(16))
                .lineLimit(1)
                .frame(width: Theme.posterWidth, alignment: .leading)
        }
    }
}
