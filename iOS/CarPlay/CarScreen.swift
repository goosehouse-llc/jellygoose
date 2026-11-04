import AVFoundation
import SwiftUI

/// The car's screen, drawn by the app (see `CarScreenSceneDelegate`): tabs
/// along the top, rows of posters, and the picture full screen. Laid out
/// after CarTV's (an IPTV player for CarPlay): a car's screen is wide and short, and
/// touched at arm's length.
struct CarScreen: View {
    @ObservedObject var model: CarScreenModel

    var body: some View {
        GeometryReader { geometry in
            let metrics = CarMetrics(width: geometry.size.width)
            ZStack(alignment: .bottom) {
                Color(white: 0.09).ignoresSafeArea()
                VStack(spacing: 0) {
                    CarTopBar(model: model)
                    content(metrics)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if let playing = model.playing, !model.showsPlayer {
                    CarMiniPlayer(model: model, playing: playing)
                        .padding(.bottom, 6)
                }
                if model.showsPlayer {
                    // Clear of CarPlay's own column down the side of the
                    // screen, which lies over the app's window.
                    if model.playsMusic {
                        CarMusicScreen(model: model)
                            .transition(.opacity)
                    } else {
                        CarPlayerScreen(model: model)
                            .transition(.opacity)
                    }
                }
                if let notice = model.notice {
                    Text(notice)
                        .font(.app(13, .semibold))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(Color(white: 0.22)))
                        .padding(.bottom, 12)
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            model.notice = nil
                        }
                }
            }
            .environment(\.carMetrics, metrics)
        }
        .foregroundStyle(.white)
        .animation(.easeOut(duration: 0.2), value: model.showsPlayer)
    }

    @ViewBuilder
    private func content(_ metrics: CarMetrics) -> some View {
        if !model.signedIn {
            CarMessage(symbol: "iphone", text: String(localized: "Open JellyGoose on your iPhone to sign in",
                                                      comment: "Shown on the car's display when nobody is signed in"))
        } else {
            // Each screen stays where it was under the one opened from it,
            // so Back finds a long library scrolled as far as it was.
            ZStack {
                Group {
                    switch model.tab {
                    case .home: CarHome(model: model)
                    case .music: CarMusicHome(model: model)
                    case .liveTV: CarChannels(model: model)
                    case .search: CarSearch(model: model)
                    }
                }
                .opacity(model.pages.isEmpty ? 1 : 0)
                .allowsHitTesting(model.pages.isEmpty)
                ForEach(Array(model.pages.enumerated()), id: \.offset) { index, page in
                    let top = index == model.pages.count - 1
                    Group {
                        switch page {
                        case .titles(let parent):
                            CarTitlesPage(model: model, parent: parent).id(parent.id)
                        case .show(let id, _, let season):
                            CarShowPage(model: model, showId: id, season: season).id(id)
                        case .songs(let container):
                            CarSongsPage(model: model, container: container).id(container.id)
                        case .albums(let parent):
                            CarMusicGridPage(model: model, parent: parent).id(parent.id)
                        case .artists(let library):
                            CarMusicGridPage(model: model, parent: library, artists: true).id("artists-" + library.id)
                        }
                    }
                    .opacity(top ? 1 : 0)
                    .allowsHitTesting(top)
                    .accessibilityHidden(!top)
                }
            }
        }
    }
}

// MARK: - Sizes

/// Sizes for the car's screen, which may be 400 points wide or 900.
struct CarMetrics {
    let width: CGFloat
    /// About four posters and a bit across, as CarTV has.
    var poster: CGFloat { min(max((width - 24) / 4.4, 76), 128) }
    var wide: CGFloat { poster * 1.75 }
    let margin: CGFloat = 12
}

private struct CarMetricsKey: EnvironmentKey {
    static let defaultValue = CarMetrics(width: 400)
}

extension EnvironmentValues {
    var carMetrics: CarMetrics {
        get { self[CarMetricsKey.self] }
        set { self[CarMetricsKey.self] = newValue }
    }
}

// MARK: - The top bar

private struct CarTopBar: View {
    @ObservedObject var model: CarScreenModel

    var body: some View {
        HStack(spacing: 8) {
            if let page = model.pages.last {
                CarRoundButton(symbol: "chevron.left") { model.back() }
                Text(title(of: page))
                    .font(.app(16, .bold))
                    .lineLimit(1)
                Spacer(minLength: 0)
            } else {
                HStack(spacing: 2) {
                    tab(.home, String(localized: "Home", comment: "Menu section: the home screen"))
                    if !model.musicLibraries.isEmpty {
                        tab(.music, String(localized: "Music", comment: "Eyebrow above a music library's name"))
                    }
                    if !model.channels.isEmpty {
                        tab(.liveTV, String(localized: "Live TV", comment: "Menu section: the server's television channels"))
                    }
                }
                .padding(3)
                .background(Capsule().fill(.white.opacity(0.1)))
                Spacer(minLength: 0)
                CarRoundButton(symbol: "magnifyingglass", selected: model.tab == .search) { model.tab = .search }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    private func title(of page: CarScreenModel.Page) -> String {
        switch page {
        case .titles(let parent): parent.displayTitle
        case .show(_, let name, _): name
        case .songs(let container): container.displayTitle
        case .albums(let parent): parent.isArtist ? parent.displayTitle
            : String(localized: "Albums", comment: "Music library: its albums")
        case .artists: String(localized: "Artists", comment: "Music library: who made its albums")
        }
    }

    private func tab(_ tab: CarScreenModel.Tab, _ title: String) -> some View {
        Button { model.tab = tab } label: {
            Text(title)
                .font(.app(14, .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Capsule().fill(model.tab == tab ? Theme.accent : .clear))
                .foregroundStyle(model.tab == tab ? .white : .white.opacity(0.7))
        }
        .buttonStyle(CarPress())
    }
}

private struct CarRoundButton: View {
    let symbol: String
    var selected = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .bold))
                .frame(width: 36, height: 36)
                .background(Circle().fill(selected ? Theme.accent : .white.opacity(0.12)))
        }
        .buttonStyle(CarPress())
    }
}

private struct CarMessage: View {
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 30))
            Text(text).font(.app(15, .semibold)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Home

private struct CarHome: View {
    @ObservedObject var model: CarScreenModel
    @Environment(\.carMetrics) private var metrics

    var body: some View {
        if model.shelves.isEmpty {
            if model.loaded {
                CarMessage(symbol: "film.stack", text: String(localized: "Nothing here yet."))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(model.shelves) { shelf in
                        CarShelfView(model: model, shelf: shelf)
                    }
                }
                .padding(.vertical, 6)
                .padding(.bottom, model.playing == nil ? 0 : 40)
            }
            .refreshable { model.reload() }
        }
    }
}

private struct CarShelfView: View {
    @ObservedObject var model: CarScreenModel
    let shelf: CarScreenModel.Shelf
    @Environment(\.carMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                if let library = shelf.library { model.pages.append(.titles(library)) }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(shelf.title).font(.app(16, .bold))
                    if let detail = shelf.detail {
                        Text(detail).font(.app(12, .semibold)).foregroundStyle(.white.opacity(0.5))
                    }
                    if shelf.library != nil {
                        Image(systemName: "chevron.right").font(.system(size: 12, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                    }
                }
            }
            .buttonStyle(CarPress())
            .disabled(shelf.library == nil)
            .padding(.horizontal, metrics.margin)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 8) {
                    ForEach(shelf.items) { item in
                        Button { model.open(item) } label: {
                            if shelf.wide {
                                CarWideCard(model: model, item: item)
                            } else {
                                CarPosterCard(model: model, item: item)
                            }
                        }
                        .buttonStyle(CarPress())
                    }
                }
                .padding(.horizontal, metrics.margin)
            }
        }
    }
}

struct CarPosterCard: View {
    @ObservedObject var model: CarScreenModel
    let item: BaseItem
    @Environment(\.carMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            RemoteImage(url: model.posterURL(item))
                .frame(width: metrics.poster, height: metrics.poster * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottom) { progress }
            Text(item.displayTitle).font(.app(12, .semibold)).lineLimit(1)
                .frame(width: metrics.poster, alignment: .leading)
        }
    }

    @ViewBuilder
    private var progress: some View {
        if let fraction = item.carProgress {
            CarProgressBar(fraction: fraction).padding(5)
        }
    }
}

struct CarWideCard: View {
    @ObservedObject var model: CarScreenModel
    let item: BaseItem
    @Environment(\.carMetrics) private var metrics

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            RemoteImage(url: model.wideURL(item))
                .frame(width: metrics.wide, height: metrics.wide * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottom) {
                    if let fraction = item.carProgress { CarProgressBar(fraction: fraction).padding(5) }
                }
            Text(item.isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle).font(.app(12, .semibold)).lineLimit(1)
            if item.isEpisode {
                Text([item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")).font(.app(11, .semibold))
                    .foregroundStyle(.white.opacity(0.55)).lineLimit(1)
            }
        }
        .frame(width: metrics.wide, alignment: .leading)
    }
}

private struct CarProgressBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Theme.accent).frame(width: geometry.size.width * fraction)
            }
        }
        .frame(height: 3)
    }
}

extension BaseItem {
    /// How far through it is, where it's been started and not finished.
    fileprivate var carProgress: Double? {
        guard let runtime = runTimeTicks, runtime > 0, resumeTicks > 0 else { return nil }
        return min(1, Double(resumeTicks) / Double(runtime))
    }
}

// MARK: - A library

/// A library's titles in a grid, by name, fetched a page at a time as the
/// grid is scrolled: a library of thousands is too many to ask for at once.
/// Letter keys along the top go straight to a letter: the grid then starts
/// there, with a way back to what comes before.
private struct CarTitlesPage: View {
    @ObservedObject var model: CarScreenModel
    let parent: BaseItem
    @Environment(\.carMetrics) private var metrics
    @State private var items: [BaseItem] = []
    /// Where in the library `items` begins.
    @State private var first = 0
    @State private var total: Int?
    @State private var loading = false
    @State private var letter: String?

    /// "#" is what's filed before A.
    private static let letters = ["#"] + (65...90).map { String(UnicodeScalar($0)) }

    var body: some View {
        VStack(spacing: 4) {
            if total.map({ $0 > 60 }) ?? false { letterKeys }
            ScrollViewReader { scroller in
                ScrollView(.vertical) {
                    if first > 0 {
                        Button { Task { await earlier() } } label: {
                            Label(String(localized: "Earlier Titles", comment: "On the car's display: shows the titles before the letter gone to"),
                                  systemImage: "chevron.up")
                                .font(.app(13, .semibold))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                        .buttonStyle(CarPress())
                        .padding(.top, 4)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.poster, maximum: metrics.poster * 1.2), spacing: 8)],
                              alignment: .leading, spacing: 10) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            Button { model.open(item) } label: {
                                CarPosterCard(model: model, item: item)
                            }
                            .buttonStyle(CarPress())
                            .id(item.id)
                            .onAppear { if index >= items.count - 12 { Task { await more() } } }
                        }
                    }
                    .padding(.horizontal, metrics.margin)
                    .padding(.vertical, 6)
                    .padding(.bottom, model.playing == nil ? 0 : 40)
                    if loading { ProgressView().padding() }
                }
                .onChange(of: letter) { _, _ in
                    if let top = items.first { scroller.scrollTo(top.id, anchor: .top) }
                }
            }
        }
        .task { await more() }
    }

    private var letterKeys: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Self.letters, id: \.self) { key in
                    Button { Task { await go(to: key) } } label: {
                        Text(key)
                            .font(.app(14, .bold))
                            .frame(width: 32, height: 30)
                            .background(RoundedRectangle(cornerRadius: 7)
                                .fill(letter == key ? Theme.accent : .white.opacity(0.12)))
                    }
                    .buttonStyle(CarPress())
                }
            }
            .padding(.horizontal, metrics.margin)
        }
    }

    private var kind: String {
        parent.isLibrary ? CarScreenModel.kind(of: parent) : "Movie,Series,Video"
    }

    /// The titles from a letter on. Where it starts is how many come before
    /// it by name, which the server counts (as the phone's grid finds a
    /// letter).
    private func go(to key: String) async {
        guard let client = model.client else { return }
        var start = 0
        if key != "#" {
            guard let before = try? await client.libraryItems(parentId: parent.id, limit: 0, itemTypes: kind,
                                                              nameLessThan: key) else { return }
            start = before.totalRecordCount ?? 0
        }
        first = start
        items = []
        letter = key
        await more()
    }

    private func more() async {
        guard !loading, let client = model.client, total.map({ first + items.count < $0 }) ?? true else { return }
        loading = true
        defer { loading = false }
        guard let page = try? await client.libraryItems(parentId: parent.id, startIndex: first + items.count, limit: 60,
                                                        itemTypes: kind) else { return }
        items += page.items
        total = page.totalRecordCount ?? first + items.count
    }

    /// The page before the letter gone to, put above it.
    private func earlier() async {
        guard !loading, let client = model.client, first > 0 else { return }
        loading = true
        defer { loading = false }
        let start = max(0, first - 60)
        guard let page = try? await client.libraryItems(parentId: parent.id, startIndex: start, limit: first - start,
                                                        itemTypes: kind) else { return }
        items = page.items + items
        first = start
    }
}

// MARK: - A show

private struct CarShowPage: View {
    @ObservedObject var model: CarScreenModel
    let showId: String
    let season: String?
    @Environment(\.carMetrics) private var metrics
    @State private var show: BaseItem?
    @State private var seasons: [BaseItem] = []
    @State private var chosen: String?
    @State private var episodes: [BaseItem] = []
    @State private var next: BaseItem?

    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if let next {
                    Button { model.play(next) } label: {
                        Label(next.resumeTicks > 0
                                  ? String(localized: "Resume \(next.episodeLabel ?? next.displayTitle)")
                                  : String(localized: "Play \(next.episodeLabel ?? next.displayTitle)"),
                              systemImage: "play.fill")
                            .font(.app(14, .bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 9)
                            .background(Capsule().fill(Theme.accent))
                    }
                    .buttonStyle(CarPress())
                }
                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(seasons) { season in
                                Button { chosen = season.id } label: {
                                    Text(season.displayTitle)
                                        .font(.app(13, .semibold))
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 6)
                                        .background(Capsule().fill(chosen == season.id ? .white.opacity(0.25) : .white.opacity(0.08)))
                                }
                                .buttonStyle(CarPress())
                            }
                        }
                    }
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(episodes) { episode in
                        Button { model.play(episode) } label: { row(for: episode) }
                            .buttonStyle(CarPress())
                    }
                }
            }
            .padding(.horizontal, metrics.margin)
            .padding(.vertical, 6)
            .padding(.bottom, model.playing == nil ? 0 : 40)
        }
        .task { await load() }
        .task(id: chosen) { await loadEpisodes() }
    }

    private func row(for episode: BaseItem) -> some View {
        HStack(spacing: 10) {
            RemoteImage(url: model.wideURL(episode))
                .frame(width: metrics.wide * 0.7, height: metrics.wide * 0.7 * 9 / 16)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottom) {
                    if let fraction = episode.carProgress { CarProgressBar(fraction: fraction).padding(4) }
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.displayTitle).font(.app(14, .semibold)).lineLimit(1)
                if let label = episode.episodeLabel {
                    Text(label).font(.app(12, .semibold)).foregroundStyle(.white.opacity(0.55))
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    private func load() async {
        guard let client = model.client else { return }
        async let all = try? client.seasons(seriesId: showId)
        async let upNext = client.nextEpisode(seriesId: showId)
        seasons = await all ?? []
        next = await upNext
        chosen = season ?? next?.seasonId ?? seasons.first?.id
    }

    private func loadEpisodes() async {
        guard let client = model.client, let chosen else { return }
        episodes = (try? await client.episodes(seriesId: showId, seasonId: chosen)) ?? []
    }
}

// MARK: - Live TV

private struct CarChannels: View {
    @ObservedObject var model: CarScreenModel
    @Environment(\.carMetrics) private var metrics

    var body: some View {
        ScrollView(.vertical) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: metrics.wide * 0.8), spacing: 8)], spacing: 8) {
                ForEach(model.channels) { channel in
                    Button { model.tune(channel) } label: { CarChannelCard(model: model, channel: channel) }
                        .buttonStyle(CarPress())
                }
            }
            .padding(.horizontal, metrics.margin)
            .padding(.vertical, 6)
            .padding(.bottom, model.playing == nil ? 0 : 40)
        }
    }
}

private struct CarChannelCard: View {
    @ObservedObject var model: CarScreenModel
    let channel: LiveChannel

    var body: some View {
        HStack(spacing: 8) {
            RemoteImage(url: model.logoURL(channel), contentMode: .fit)
                .frame(width: 44, height: 30)
            VStack(alignment: .leading, spacing: 1) {
                Text([channel.number, channel.name].compactMap { $0 }.joined(separator: " ")).font(.app(12, .bold)).lineLimit(1)
                if let now = channel.now?.name {
                    Text(now).font(.app(11, .semibold)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.08)))
    }
}

// MARK: - Search

/// A search typed on keys drawn here: the car's screen has no keyboard of
/// its own for the app.
private struct CarSearch: View {
    @ObservedObject var model: CarScreenModel
    @Environment(\.carMetrics) private var metrics
    @State private var term = ""
    @State private var results: [BaseItem] = []
    /// Artists, albums and songs, where the account has music.
    @State private var music: [BaseItem] = []

    private static let rows = ["QWERTYUIOP", "ASDFGHJKL", "ZXCVBNM"]

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.5))
                Text(term.isEmpty ? String(localized: "Search") : term)
                    .font(.app(14, .semibold))
                    .foregroundStyle(term.isEmpty ? .white.opacity(0.4) : .white)
                Spacer()
            }
            .padding(.horizontal, metrics.margin)
            if !results.isEmpty || !music.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 8) {
                        ForEach(results) { item in
                            Button { model.open(item) } label: { CarPosterCard(model: model, item: item) }
                                .buttonStyle(CarPress())
                        }
                        ForEach(music) { item in
                            Button { model.open(item) } label: { CarSquareCard(model: model, item: item) }
                                .buttonStyle(CarPress())
                        }
                    }
                    .padding(.horizontal, metrics.margin)
                }
                .scaleEffect(0.7, anchor: .topLeading)
                .frame(height: metrics.poster * 1.5 * 0.7 + 14, alignment: .top)
            }
            Spacer(minLength: 0)
            keys
        }
        .padding(.bottom, 4)
        .task(id: term) { await find() }
    }

    private var keys: some View {
        VStack(spacing: 4) {
            ForEach(Self.rows, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(Array(row), id: \.self) { letter in
                        key(String(letter)) { term.append(letter) }
                    }
                }
            }
            HStack(spacing: 4) {
                key(String(localized: "Space", comment: "The space bar on the car's search keys"), wide: true) {
                    if !term.isEmpty, !term.hasSuffix(" ") { term.append(" ") }
                }
                key("⌫") { if !term.isEmpty { term.removeLast() } }
            }
        }
        .padding(.horizontal, 6)
    }

    private func key(_ label: String, wide: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.app(14, .semibold))
                .frame(maxWidth: wide ? 160 : 34, minHeight: 30)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.14)))
        }
        .buttonStyle(CarPress())
    }

    private func find() async {
        let words = term.trimmingCharacters(in: .whitespaces)
        guard words.count >= 2, let client = model.client else { results = []; music = []; return }
        // A beat, so a word being typed isn't searched for a letter at a time.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }
        // Shows and films, not single episodes.
        results = ((try? await client.search(words)) ?? []).filter { !$0.isEpisode }
        if !model.musicLibraries.isEmpty, let found = try? await client.searchMusic(words), !Task.isCancelled {
            music = found.artists + found.albums + found.songs
        } else {
            music = []
        }
    }
}

// MARK: - The bar along the foot

private struct CarMiniPlayer: View {
    @ObservedObject var model: CarScreenModel
    let playing: CarScreenModel.Playing

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            HStack(spacing: 4) {
                Button { model.showsPlayer = true } label: {
                    HStack(spacing: 8) {
                        Text(playing.title).font(.app(13, .bold)).lineLimit(1)
                        if let subtitle = playing.subtitle {
                            Text(subtitle).font(.app(12, .semibold)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(CarPress())
                Button { model.togglePause() } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 32, height: 30)
                }
                .buttonStyle(CarPress())
                Button { model.stop() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .frame(width: 32, height: 30)
                }
                .buttonStyle(CarPress())
            }
            .padding(.leading, 14)
            .padding(.trailing, 4)
            .padding(.vertical, 2)
            .background(Capsule().fill(Color(white: 0.2)))
            .padding(.horizontal, 12)
        }
    }
}

// MARK: - Buttons

/// How the car's buttons look pressed. Not the plain style: on CarPlay that
/// lays the knob's focus highlight over a button as a rounded mask the
/// button's own size, and on a card its corners cut into the title along
/// the bottom ("ˀeason 4", "Sum.").
struct CarPress: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.55 : 1)
    }
}
