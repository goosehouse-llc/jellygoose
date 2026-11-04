import SwiftUI

// Music on the car's screen the app draws itself (see `CarScreen`): the
// Music tab, an album's or a playlist's songs, a library's albums and
// artists, and the song playing. Played by the app's one music player
// (`MusicPlayer`), so what's started in the car is what the phone shows, and
// the other way about. Sound only, so nothing here waits for the car to stop.

// MARK: - The Music tab

struct CarMusicHome: View {
    @ObservedObject var model: CarScreenModel
    @Environment(\.carMetrics) private var metrics

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 14) {
                if let library = model.musicLibraries.first {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            CarPill(title: String(localized: "Shuffle All", comment: "Plays a whole music library in no order"),
                                    symbol: "shuffle", filled: true) {
                                let client = model.client
                                model.playMusic(source: library.displayTitle, shuffled: true) {
                                    try await client?.shuffledSongs(in: library.id, limit: 300) ?? []
                                }
                            }
                            CarPill(title: String(localized: "Albums", comment: "Music library: its albums"), symbol: "square.stack") {
                                model.pages.append(.albums(library))
                            }
                            CarPill(title: String(localized: "Artists", comment: "Music library: who made its albums"), symbol: "music.mic") {
                                model.pages.append(.artists(library))
                            }
                        }
                        .padding(.horizontal, metrics.margin)
                    }
                }
                ForEach(model.musicShelves) { shelf in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(shelf.title).font(.app(16, .bold))
                            .padding(.horizontal, metrics.margin)
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 8) {
                                ForEach(Array(shelf.items.enumerated()), id: \.element.id) { place, item in
                                    Button {
                                        // Songs played last play on from the one chosen.
                                        if item.isSong {
                                            model.playMusic(shelf.items, from: place,
                                                            source: String(localized: "Recently Played", comment: "Music: the songs played last"))
                                        } else {
                                            model.open(item)
                                        }
                                    } label: {
                                        CarSquareCard(model: model, item: item)
                                    }
                                    .buttonStyle(CarPress())
                                }
                            }
                            .padding(.horizontal, metrics.margin)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.bottom, model.playing == nil ? 0 : 40)
        }
        .refreshable { model.reload() }
    }
}

/// A capsule button with a symbol: Shuffle All, Play, the library's ways in.
struct CarPill: View {
    let title: String
    let symbol: String
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.app(14, .bold))
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(filled ? Theme.accent : .white.opacity(0.12)))
        }
        .buttonStyle(CarPress())
    }
}

/// A round-ended button with a symbol alone: Play and Shuffle beside a cover.
struct CarIconPill: View {
    let symbol: String
    var filled = false
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .bold))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(Capsule().fill(filled ? Theme.accent : .white.opacity(0.12)))
        }
        .buttonStyle(CarPress())
        .accessibilityLabel(label)
    }
}

/// An album's, a playlist's, an artist's or a song's cover, with its name
/// and who it's by under it.
struct CarSquareCard: View {
    @ObservedObject var model: CarScreenModel
    let item: BaseItem
    @Environment(\.carMetrics) private var metrics

    private var side: CGFloat { metrics.poster * 1.15 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            RemoteImage(url: model.coverURL(item), symbol: item.isArtist ? "music.mic" : "music.note")
                .frame(width: side, height: side)
                .clipShape(item.isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 5)))
            Text(item.displayTitle).font(.app(12, .semibold)).lineLimit(1)
            if !item.isArtist, let by = item.byLine {
                Text(by).font(.app(11, .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .frame(width: side, alignment: .leading)
    }
}

// MARK: - An album or a playlist

/// Its cover and Play and Shuffle beside a list of its songs; a song chosen
/// plays, and the songs after it follow.
struct CarSongsPage: View {
    @ObservedObject var model: CarScreenModel
    let container: BaseItem
    @Environment(\.carMetrics) private var metrics
    @State private var songs: [BaseItem] = []
    @State private var loaded = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: model.coverURL(container, width: 480), symbol: "music.note")
                    .frame(width: side, height: side)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                if let by = container.byLine {
                    Text(by).font(.app(11, .semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
                HStack(spacing: 6) {
                    CarIconPill(symbol: "play.fill", filled: true, label: String(localized: "Play")) { play(from: 0, shuffled: false) }
                    CarIconPill(symbol: "shuffle", label: String(localized: "Shuffle")) { play(from: 0, shuffled: true) }
                }
            }
            .frame(width: side, alignment: .leading)
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if !loaded { ProgressView().padding() }
                    ForEach(Array(songs.enumerated()), id: \.element.id) { place, song in
                        Button { play(from: place, shuffled: false) } label: { row(song, place: place) }
                            .buttonStyle(CarPress())
                    }
                }
                .padding(.bottom, model.playing == nil ? 0 : 40)
            }
        }
        .padding(.horizontal, metrics.margin)
        .padding(.vertical, 6)
        .task { await load() }
    }

    private var isPlaylist: Bool { container.type == "Playlist" }

    /// The cover: as big as a poster's height allows, beside a list that
    /// wants the width.
    private var side: CGFloat { max(metrics.poster * 1.1, 84) }

    private func row(_ song: BaseItem, place: Int) -> some View {
        HStack(spacing: 10) {
            CarSongMark(songId: song.id, number: isPlaylist ? nil : (song.indexNumber ?? place + 1))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.displayTitle).font(.app(14, .semibold)).lineLimit(1)
                if isPlaylist || song.byLine != container.byLine, let by = song.byLine {
                    Text(by).font(.app(11, .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let length = song.songLength {
                Text(length).font(.app(12, .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06)))
        .contentShape(Rectangle())
    }

    private func load() async {
        guard let client = model.client else { return }
        songs = ((try? await client.tracks(of: container.id, playlist: isPlaylist)) ?? []).filter(\.isSong)
        loaded = true
    }

    private func play(from place: Int, shuffled: Bool) {
        model.playMusic(songs, from: place, shuffled: shuffled, source: container.displayTitle)
    }
}

/// The song's number on its album, or a speaker where it's the one playing.
private struct CarSongMark: View {
    @ObservedObject private var music = MusicPlayer.shared
    let songId: String
    let number: Int?

    var body: some View {
        Group {
            if music.current?.id == songId {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Theme.accent)
                    .symbolEffect(.variableColor.iterative, isActive: music.isPlaying)
            } else if let number {
                Text("\(number)").font(.app(12, .semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
            } else {
                Image(systemName: "music.note").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
        }
        .frame(width: 22)
    }
}

// MARK: - A library's albums, an artist's, a library's artists

/// A grid of covers, fetched a page at a time as it's scrolled: a library's
/// albums or artists by name, or someone's albums, newest first, with Play
/// and Shuffle for all their songs.
struct CarMusicGridPage: View {
    @ObservedObject var model: CarScreenModel
    let parent: BaseItem
    /// A library's artists rather than its albums.
    var artists = false
    @Environment(\.carMetrics) private var metrics
    @State private var items: [BaseItem] = []
    @State private var total: Int?
    @State private var loading = false

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if parent.isArtist {
                    HStack(spacing: 8) {
                        CarPill(title: String(localized: "Play"), symbol: "play.fill", filled: true) { playArtist(shuffled: false) }
                        CarPill(title: String(localized: "Shuffle"), symbol: "shuffle") { playArtist(shuffled: true) }
                    }
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.poster * 1.15, maximum: metrics.poster * 1.4), spacing: 8)],
                          alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        Button { model.open(item) } label: { CarSquareCard(model: model, item: item) }
                            .buttonStyle(CarPress())
                            .onAppear { if index >= items.count - 12 { Task { await more() } } }
                    }
                }
                if loading { ProgressView().frame(maxWidth: .infinity).padding() }
            }
            .padding(.horizontal, metrics.margin)
            .padding(.vertical, 6)
            .padding(.bottom, model.playing == nil ? 0 : 40)
        }
        .task { await more() }
    }

    private func more() async {
        guard !loading, let client = model.client, total.map({ items.count < $0 }) ?? true else { return }
        loading = true
        defer { loading = false }
        if parent.isArtist {
            // Theirs, then the ones they're on.
            async let own = try? client.albums(by: parent.id)
            async let others = try? client.albums(featuring: parent.id)
            items = (await own ?? []) + (await others ?? [])
            total = items.count
            return
        }
        guard let page = try? await client.music(artists ? .artists : .albums, in: parent.id, startIndex: items.count, limit: 60,
                                                 sortBy: "SortName", sortOrder: "Ascending") else { return }
        items += page.items
        total = page.totalRecordCount ?? items.count
    }

    private func playArtist(shuffled: Bool) {
        let client = model.client
        let artist = parent
        model.playMusic(source: artist.displayTitle, shuffled: shuffled) {
            try await client?.songs(by: artist.id, shuffled: false, limit: 1000) ?? []
        }
    }
}

// MARK: - The song playing

/// The cover beside the song's name, where it's up to, and the controls:
/// shuffle, back, play, on, repeat. Down closes it; the music plays on.
struct CarMusicScreen: View {
    @ObservedObject var model: CarScreenModel
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 520
            let side = min(geometry.size.height - 56, geometry.size.width * (compact ? 0.34 : 0.4))
            ZStack(alignment: .topLeading) {
                Color(white: 0.09).ignoresSafeArea()
                if let song = music.current {
                    RemoteImage(url: model.coverURL(song, width: 200), symbol: "music.note")
                        .blur(radius: 40)
                        .opacity(0.45)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                        .allowsHitTesting(false)
                    HStack(spacing: 18) {
                        RemoteImage(url: model.coverURL(song, width: 600), symbol: "music.note")
                            .frame(width: side, height: side)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                        VStack(alignment: .leading, spacing: 6) {
                            Text(song.displayTitle).font(.app(19, .bold)).lineLimit(2)
                            if let by = song.byLine {
                                Text(by).font(.app(14, .semibold)).foregroundStyle(.white.opacity(0.8)).lineLimit(1)
                            }
                            if let album = song.album {
                                Text(album).font(.app(12, .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                            }
                            CarMusicProgress(clock: music.clock)
                                .padding(.top, 6)
                            controls(compact: compact)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.leading, compact ? 12 : 18)
                    .padding(.trailing, compact ? 10 : 14)
                    .padding(.top, 20)
                    .frame(maxHeight: .infinity)
                }
                Button { model.showsPlayer = false } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(CarPress())
                .padding(10)
            }
        }
        .foregroundStyle(.white)
    }

    private func controls(compact: Bool) -> some View {
        let small: CGFloat = compact ? 34 : 42
        let big: CGFloat = compact ? 44 : 52
        return HStack(spacing: 0) {
            control(music.isShuffled ? "shuffle.circle.fill" : "shuffle", size: small, lit: music.isShuffled) { music.toggleShuffle() }
            Spacer(minLength: 2)
            control("backward.fill", size: small) { music.previous() }
            Spacer(minLength: 2)
            Button { music.togglePause() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: compact ? 19 : 22, weight: .bold))
                    .foregroundStyle(.black)
                    .frame(width: big, height: big)
                    .background(Circle().fill(.white))
            }
            .buttonStyle(CarPress())
            Spacer(minLength: 2)
            control("forward.fill", size: small) { music.next() }
            Spacer(minLength: 2)
            control(music.repeatMode == .one ? "repeat.1" : "repeat", size: small, lit: music.repeatMode != .off) { music.cycleRepeat() }
        }
        .padding(.top, 6)
    }

    private func control(_ symbol: String, size: CGFloat, lit: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.43, weight: .bold))
                .foregroundStyle(lit ? Theme.accent : .white)
                .frame(width: size, height: size)
        }
        .buttonStyle(CarPress())
    }
}

private struct CarMusicProgress: View {
    @ObservedObject var clock: MusicClock

    var body: some View {
        VStack(spacing: 3) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.white)
                        .frame(width: geometry.size.width * (clock.duration > 0 ? min(1, clock.position / clock.duration) : 0))
                }
            }
            .frame(height: 4)
            HStack {
                Text(NowPlayingProgress.time(clock.position))
                Spacer()
                Text("-" + NowPlayingProgress.time(max(0, clock.duration - clock.position)))
            }
            .font(.app(11, .semibold))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
        }
    }
}
