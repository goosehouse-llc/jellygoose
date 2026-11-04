import SwiftUI

// MARK: - A genre

/// A kind of music in a library: its albums, and its songs shuffled.
struct GenreView: View {
    @EnvironmentObject var app: AppState
    let genreId: String
    let libraryId: String
    let name: String

    @State private var albums: [BaseItem] = []
    @State private var total: Int?
    @State private var loaded = false
    @State private var loadingMore = false

    private static let page = 100

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.posterWidth), spacing: Theme.isPhone ? 16 : 36, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 18) {
                    ShelfHeader(title: name,
                                eyebrow: total.map { String(localized: "\($0) albums") }
                                    ?? String(localized: "Genre", comment: "Above a kind of music's name"),
                                accent: Theme.palette[2])
                    Spacer(minLength: 0)
                    Button(action: shuffle) {
                        Label(String(localized: "Shuffle"), systemImage: "shuffle")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(GradientButtonStyle())
                    Button(action: instantMix) {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    .buttonStyle(.action(active: false))
                    .accessibilityLabel(String(localized: "Instant Mix", comment: "Plays songs like this one, chosen by the server"))
                }
                .tvFocusSection()
                Group {
                    if !loaded {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if albums.isEmpty {
                        Text("Nothing here yet.")
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 40)
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.isPhone ? 20 : 44) {
                            ForEach(Array(albums.enumerated()), id: \.element.id) { place, album in
                                AlbumCard(item: album)
                                    .onAppear { more(after: place) }
                            }
                        }
                    }
                }
                .tvFocusSection()
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, Theme.isPhone ? 20 : 48)
        }
        .pageSides()
        .task(id: genreId) { await load(fresh: true) }
    }

    private func shuffle() {
        guard let client = app.client else { return }
        let (genre, library) = (genreId, libraryId)
        MusicPlayer.shared.play(source: name, shuffled: true, client: client) {
            try await client.shuffledSongs(inGenre: genre, library: library, limit: 300)
        }
    }

    private func instantMix() {
        guard let client = app.client else { return }
        let id = genreId
        MusicPlayer.shared.play(source: String(localized: "Instant Mix"), client: client) {
            try await client.instantMix(from: id, limit: 200)
        }
    }

    private func more(after place: Int) {
        guard place >= albums.count - 12, !loadingMore, let total, albums.count < total else { return }
        loadingMore = true
        Task { await load(fresh: false) }
    }

    private func load(fresh: Bool) async {
        guard let client = app.client else { loadingMore = false; return }
        if !fresh { loadingMore = true }
        defer { loadingMore = false }
        let askedAt = Date()
        guard let result = try? await client.albums(inGenre: genreId, library: libraryId,
                                                    startIndex: fresh ? 0 : albums.count, limit: Self.page) else {
            loaded = true
            return
        }
        if fresh {
            albums = result.items
        } else {
            let have = Set(albums.map(\.id))
            albums += result.items.filter { !have.contains($0.id) }
        }
        MusicFavorites.shared.heard(result.items, askedAt: askedAt)
        total = result.totalRecordCount ?? albums.count
        loaded = true
    }
}

// MARK: - Lists of songs and albums

/// A list of songs to play from somewhere other than an album: everything
/// someone sings on, the songs played most.
struct SongListView: View {
    @EnvironmentObject var app: AppState
    let title: String
    let eyebrow: String
    /// What Now Playing says the songs came from.
    var source: String? = nil
    let loader: (any MediaServer) async throws -> [BaseItem]

    @State private var songs: [BaseItem] = []
    @State private var loaded = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .bottom, spacing: 18) {
                    ShelfHeader(title: title, eyebrow: eyebrow, accent: Theme.palette[1])
                    Spacer(minLength: 0)
                    Button { play(from: 0, shuffled: false) } label: {
                        Label(String(localized: "Play"), systemImage: "play.fill")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(GradientButtonStyle())
                    Button { play(from: 0, shuffled: true) } label: {
                        Label(String(localized: "Shuffle"), systemImage: "shuffle")
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .buttonStyle(.pill(selected: false))
                }
                .tvFocusSection()
                Group {
                    if !loaded {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                    } else if songs.isEmpty {
                        Text("Nothing here yet.")
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 40)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { place, song in
                                TrackRow(song: song, showsArtist: true, showsAlbum: true) {
                                    play(from: place, shuffled: false)
                                }
                            }
                        }
                    }
                }
                .tvFocusSection()
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, Theme.isPhone ? 20 : 48)
        }
        .pageSides()
        .task {
            guard let client = app.client else { return }
            let askedAt = Date()
            songs = ((try? await loader(client)) ?? []).filter(\.isSong)
            MusicFavorites.shared.heard(songs, askedAt: askedAt)
            loaded = true
        }
    }

    private func play(from place: Int, shuffled: Bool) {
        guard let client = app.client, !songs.isEmpty else { return }
        MusicPlayer.shared.play(songs, from: place, shuffled: shuffled, source: source ?? title, client: client)
    }
}

/// A grid of albums from somewhere other than a library: those played last.
struct AlbumGridView: View {
    @EnvironmentObject var app: AppState
    let title: String
    let eyebrow: String
    let loader: (any MediaServer) async throws -> [BaseItem]

    @State private var albums: [BaseItem] = []
    @State private var loaded = false

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.posterWidth), spacing: Theme.isPhone ? 16 : 36, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShelfHeader(title: title, eyebrow: eyebrow, accent: Theme.palette[0])
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .focusable()
                } else if albums.isEmpty {
                    Text("Nothing here yet.")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 40)
                        .focusable()
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.isPhone ? 20 : 44) {
                        ForEach(albums) { AlbumCard(item: $0) }
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, Theme.isPhone ? 20 : 48)
        }
        .pageSides()
        .task {
            guard let client = app.client else { return }
            let askedAt = Date()
            albums = (try? await loader(client)) ?? []
            MusicFavorites.shared.heard(albums, askedAt: askedAt)
            loaded = true
        }
    }
}
