import SwiftUI

// MARK: - What a book is

/// An audiobook as the app lists it. The server keeps one item per file: a
/// book in one file (an .m4b, with its chapters) is that file; a book in
/// parts is the files of one folder that share the book's name.
struct Audiobook: Identifiable, Hashable {
    /// Its file's id; a book in parts, its folder's and its name (a folder
    /// may hold more than one).
    let id: String
    /// What its page is opened by: the file, or the folder.
    let itemId: String
    /// The name its parts share (see `Audiobooks.name`).
    let name: String
    let title: String
    let author: String?
    let year: Int?
    /// Whose picture is its cover: the file, or the folder.
    let cover: BaseItem
    let partCount: Int
    let added: String?

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var route: BookRoute { BookRoute(id: itemId, title: title, name: partCount > 1 ? name : nil) }
}

/// A book's page, by its file or its folder (and which book of the folder's).
struct BookRoute: Hashable {
    let id: String
    var title: String? = nil
    /// For a folder: the name of its book (`Audiobooks.name`).
    var name: String? = nil
}

enum Audiobooks {
    /// A library's files made into books: parts of one folder with one name
    /// are a book; any other file is one.
    /// The name a book's parts share: the album they're tagged with, else
    /// the file's own title (so untagged files are a book apiece).
    static func name(_ file: BaseItem) -> String { file.album ?? file.displayTitle }

    /// In the order they're listened to.
    static func ordered(_ parts: [BaseItem]) -> [BaseItem] {
        parts.sorted { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.sortName ?? $0.displayTitle)
                       < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.sortName ?? $1.displayTitle) }
    }

    static func books(from files: [BaseItem], folders: [String: BaseItem]) -> [Audiobook] {
        let grouped = Dictionary(grouping: files) { ($0.parentId ?? $0.id) + "|" + name($0) }
        var books: [Audiobook] = []
        for (key, parts) in grouped {
            let ordered = ordered(parts)
            guard let first = ordered.first else { continue }
            if ordered.count > 1, let folderId = first.parentId {
                let folder = folders[folderId]
                books.append(Audiobook(id: key, itemId: folderId, name: name(first),
                                       title: first.album ?? folder?.displayTitle ?? first.displayTitle,
                                       author: first.byLine, year: first.productionYear,
                                       cover: folder ?? first, partCount: ordered.count,
                                       added: ordered.compactMap(\.dateCreated).max()))
            } else {
                books.append(Audiobook(id: first.id, itemId: first.id, name: name(first),
                                       title: first.album ?? first.displayTitle, author: first.byLine,
                                       year: first.productionYear, cover: first, partCount: 1,
                                       added: first.dateCreated))
            }
        }
        return books
    }

    /// A book's parts, in order, with their chapters: the file alone, or
    /// those of its folder with its name.
    static func parts(of route: BookRoute, client: any MediaServer) async throws -> [BaseItem] {
        guard let name = route.name else { return try await client.audiobookParts(of: route.id) }
        let all = try await client.audiobookParts(of: route.id, folder: true)
        let mine = all.filter { Self.name($0) == name }
        return mine.isEmpty ? all : ordered(mine)
    }

    /// Where to carry on: the first part part-way through, else the first
    /// not finished; a book finished, from its start.
    @MainActor
    static func resumePoint(_ parts: [BaseItem]) -> (index: Int, seconds: Double) {
        if let place = parts.firstIndex(where: { position(of: $0) > 0 && $0.userData?.played != true }) {
            return (place, Double(position(of: parts[place])) / 10_000_000)
        }
        return (parts.firstIndex { $0.userData?.played != true } ?? 0, 0)
    }

    /// How much of it is left, from where it would carry on.
    /// Where a part was left: on the device, if it was listened to there
    /// without the server hearing; else as the server has it.
    @MainActor
    private static func position(of part: BaseItem) -> Int64 {
        #if !os(tvOS)
        Downloads.shared.position(of: part)
        #else
        part.userData?.playbackPositionTicks ?? 0
        #endif
    }

    @MainActor
    static func secondsLeft(_ parts: [BaseItem]) -> Double {
        let point = resumePoint(parts)
        let lengths = parts.map { Double($0.runTimeTicks ?? 0) / 10_000_000 }
        guard lengths.indices.contains(point.index) else { return 0 }
        return lengths[point.index...].reduce(0, +) - point.seconds
    }

    static func isStarted(_ parts: [BaseItem]) -> Bool {
        parts.contains { ($0.userData?.playbackPositionTicks ?? 0) > 0 || $0.userData?.played == true }
    }

    static func isFinished(_ parts: [BaseItem]) -> Bool {
        !parts.isEmpty && parts.allSatisfy { $0.userData?.played == true }
    }

    /// Plays it from where it was left, or from a part and a place in it.
    @MainActor
    static func play(_ parts: [BaseItem], title: String, from index: Int? = nil, at seconds: Double = 0, client: any MediaServer) {
        let point = index.map { ($0, seconds) } ?? resumePoint(parts)
        MusicPlayer.shared.play(parts, from: point.0, source: title, startAt: point.1, client: client)
    }

    /// Carries on with the book a file is of (Continue Listening, Siri).
    @MainActor
    static func resume(_ file: BaseItem, client: any MediaServer) {
        Task {
            // Its folder's files of its name are its book; the file is among
            // them, with its chapters, so nothing more need be asked.
            let name = name(file)
            var parts: [BaseItem] = []
            if let folder = file.parentId, let siblings = try? await client.audiobookParts(of: folder, folder: true) {
                parts = ordered(siblings.filter { Self.name($0) == name })
            }
            if !parts.contains(where: { $0.id == file.id }) {
                parts = (try? await client.audiobookParts(of: file.id, folder: false)) ?? []
            }
            guard !parts.isEmpty else { return }
            play(parts, title: name, client: client)
        }
    }

    /// "5 hr 12 min", "42 min".
    static func length(_ seconds: Double) -> String {
        let minutes = max(1, Int(seconds / 60))
        return minutes >= 60 ? String(localized: "\(minutes / 60) hr \(minutes % 60) min", comment: "An album's length")
                             : String(localized: "\(minutes) min", comment: "An album's length")
    }
}

// MARK: - Cards

/// A book: its cover, its name and who wrote it, opening its page.
struct BookCard: View {
    @Environment(\.appState) private var app
    let book: Audiobook
    var width: CGFloat? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: book.route) {
                BookCover(item: book.cover)
                    .keepsCardCorners()
                    .frame(width: width)
            }
            .buttonStyle(.tvCard)
            .ownContextMenu(book.cover) { menu }
            .accessibilityLabel([book.title, book.author].compactMap { $0 }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 2) {
                Text(book.title)
                    .font(.app(16))
                    .lineLimit(1)
                if let author = book.author {
                    Text(author)
                        .font(.app(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }

    /// Its own long press: carry on, or mark it.
    private var menu: (heading: ItemMenuRequest.Heading, rows: [ItemMenuAction])? {
        guard let client = app?.client else { return nil }
        let book = book
        let heading = ItemMenuRequest.Heading(eyebrow: String(localized: "Audiobook", comment: "Kind of item, shown in capitals above its title"),
                                              title: book.title, detail: book.author,
                                              picture: client.imageURL(for: book.cover, type: "Primary", maxWidth: 300), fits: true)
        return (heading, [
            ItemMenuAction(title: String(localized: "Play"), icon: "play.fill") {
                Task {
                    guard let parts = try? await Audiobooks.parts(of: book.route, client: client) else { return }
                    Audiobooks.play(parts, title: book.title, client: client)
                }
            },
            ItemMenuAction(title: String(localized: "Mark as Finished", comment: "An audiobook's long press: marks every part of it listened to"),
                           icon: "checkmark.circle") {
                Task {
                    guard let parts = try? await Audiobooks.parts(of: book.route, client: client) else { return }
                    for part in parts { try? await client.setPlayed(part.id, true) }
                    app?.userDataChanged(audiobooks: true)
                }
            },
        ])
    }
}

/// A book's cover, square, or its name on the scheme's colours.
struct BookCover: View {
    @Environment(\.appState) private var app
    let item: BaseItem
    var maxWidth = 440

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                RemoteImage(url: app?.client?.imageURL(for: item, type: "Primary", maxWidth: maxWidth), symbol: "books.vertical")
            }
            .clipped()
            // Touches inside the frame only: a filled picture spills past it.
            .contentShape(.interaction, Rectangle())
    }
}

/// A book part-way through (Continue Listening): its cover with how far
/// along, chosen to carry on.
struct ListeningCard: View {
    @Environment(\.appState) private var app
    let item: BaseItem
    var width: CGFloat? = nil
    var focus: FocusState<String?>.Binding? = nil
    var focusID: String? = nil
    let play: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: play) {
                BookCover(item: item)
                    .overlay(alignment: .bottom) {
                        if let fraction = item.progressFraction {
                            WatchProgressBar(fraction: fraction)
                                .padding(.horizontal, 10)
                                .padding(.bottom, 8)
                        }
                    }
                    .keepsCardCorners()
                    .frame(width: width)
            }
            .buttonStyle(.tvCard)
            .focused(by: focus, id: focusID ?? item.id)
            .accessibilityLabel([item.album ?? item.displayTitle, item.byLine].compactMap { $0 }.joined(separator: ", "))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.album ?? item.displayTitle)
                    .font(.app(16))
                    .lineLimit(1)
                if let author = item.byLine {
                    Text(author)
                        .font(.app(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }
}

// MARK: - A library of books

/// A library's audiobooks: what's being listened to, then every book.
struct AudiobookLibraryView: View {
    @EnvironmentObject var app: AppState
    let library: BaseItem

    enum Order: CaseIterable {
        case title, author, added

        var label: String {
            switch self {
            case .title: String(localized: "Title")
            case .author: String(localized: "Author", comment: "Audiobooks: sort by who wrote them")
            case .added: String(localized: "Recently Added")
            }
        }
    }

    @State private var books: [Audiobook] = []
    /// `books` in `order`.
    @State private var sorted: [Audiobook] = []
    @State private var listening: [BaseItem] = []
    @State private var loaded = false
    @State private var order: Order = .title

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: Theme.posterWidth), spacing: Theme.isPhone ? 16 : 36, alignment: .top)]
    }

    private static func sort(_ books: [Audiobook], by order: Order) -> [Audiobook] {
        switch order {
        case .title: books.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author: books.sorted { (($0.author ?? ""), $0.title) < (($1.author ?? ""), $1.title) }
        case .added: books.sorted { ($0.added ?? "") > ($1.added ?? "") }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .bottom, spacing: 18) {
                    ShelfHeader(title: library.displayTitle,
                                eyebrow: loaded ? library.countText(books.count)
                                                : String(localized: "Audiobooks", comment: "Eyebrow above a library of books, and Home's row of them"),
                                accent: Theme.palette[2])
                    Spacer(minLength: 0)
                    Button {
                        let all = Order.allCases
                        order = all[((all.firstIndex(of: order) ?? 0) + 1) % all.count]
                    } label: {
                        Label(order.label, systemImage: "arrow.up.arrow.down")
                    }
                    .buttonStyle(.chip(active: false))
                }
                .tvFocusSection()
                if !listening.isEmpty {
                    Shelf(title: String(localized: "Continue Listening", comment: "Audiobooks part-way through"), accent: Theme.palette[0]) {
                        ForEach(listening) { file in
                            ListeningCard(item: file, width: Theme.posterWidth) {
                                guard let client = app.client else { return }
                                Audiobooks.resume(file, client: client)
                            }
                        }
                    }
                    .tvFocusSection()
                }
                Group {
                    if !loaded {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .focusable()
                    } else if books.isEmpty {
                        Text("No audiobooks here. Books on your server that are sound, not pages, show up here.",
                             comment: "A library of books with no audiobooks in it")
                            .foregroundStyle(Theme.textSecondary)
                            .padding(.top, 20)
                            .focusable()
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.isPhone ? 20 : 44) {
                            ForEach(sorted) { BookCard(book: $0) }
                        }
                    }
                }
                .tvFocusSection()
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, Theme.isPhone ? 20 : 48)
        }
        .pageSides()
        .task(id: library.id) { await load() }
        .onChange(of: app.audiobookRevision) { _, _ in Task { await load() } }
        .onChange(of: order) { _, order in sorted = Self.sort(books, by: order) }
        // A book stopped: where it's got to, in Continue Listening.
        .background(PlayerStopped { item in
            guard item?.isAudiobook != false else { return }
            Task { await refreshListening() }
        })
    }

    private func refreshListening() async {
        guard let client = app.client else { return }
        try? await Task.sleep(for: .seconds(1))   // the server hears where it stopped first
        guard let found = try? await client.resumeAudiobooks(limit: 12) else { return }
        let listened = found.filter { file in books.contains { $0.itemId == file.id || $0.itemId == file.parentId } }
        guard listened.map(\.id) != listening.map(\.id) || listened.map(\.userData?.playbackPositionTicks) != listening.map(\.userData?.playbackPositionTicks)
        else { return }
        app.holdMenuFocus()
        listening = listened
    }

    private func load() async {
        guard let client = app.client else { return }
        async let resuming = try? client.resumeAudiobooks(limit: 12)
        let files = (try? await client.audiobookFiles(in: library.id)) ?? []
        // The folders of books in parts, for their names and covers.
        let counts = Dictionary(grouping: files.compactMap(\.parentId)) { $0 }.filter { $0.value.count > 1 }
        let folders = (try? await client.items(ids: Array(counts.keys))) ?? []
        let built = Audiobooks.books(from: files, folders: Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }))
        let here = Set(files.map(\.id))
        let listened = (await resuming ?? []).filter { here.contains($0.id) }
        if loaded { app.holdMenuFocus() }
        books = built
        sorted = Self.sort(built, by: order)
        listening = listened
        loaded = true
    }
}

/// Tells of the music player stopping (a pause, an end), with what it was
/// playing; its own small view, so the page it's on doesn't redraw for every
/// change in the player.
private struct PlayerStopped: View {
    @ObservedObject private var music = MusicPlayer.shared
    let action: (BaseItem?) -> Void

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: music.isPlaying) { _, playing in
                if !playing { action(music.current) }
            }
    }
}

// MARK: - A book

/// A book: its cover and what it is, carrying on from where it was left,
/// and its chapters (or parts) to start from.
struct AudiobookView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.isNarrow) private var narrowClass
    let route: BookRoute

    @State private var parts: [BaseItem] = []
    /// Each place to start from (see `places`), worked out as it loads.
    @State private var chapters: [(title: String, part: Int, start: Double, length: Double)] = []
    @State private var loaded = false
    @State private var width: CGFloat = 0
    @FocusState private var playFocused: Bool

    private var first: BaseItem? { parts.first }
    private var title: String { route.title ?? first?.album ?? first?.displayTitle ?? "" }

    #if os(tvOS)
    private let coverSide: CGFloat = 400
    #else
    private var coverSide: CGFloat { narrow ? (Theme.isPhone ? 240 : 320) : 320 }
    #endif

    private var narrow: Bool {
        #if !os(tvOS)
        narrowClass || (width > 0 && width < 900)
        #else
        false
        #endif
    }

    /// Each place to start from: a chapter of the one file, or a part.
    private static func places(_ parts: [BaseItem]) -> [(title: String, part: Int, start: Double, length: Double)] {
        if parts.count == 1, let file = parts.first, file.bookChapters.count > 1 {
            let marks = file.bookChapters
            let total = Double(file.runTimeTicks ?? 0) / 10_000_000
            return marks.enumerated().map { place, mark in
                let end = place + 1 < marks.count ? marks[place + 1].startSeconds : total
                return (mark.name ?? String(localized: "Chapter \(place + 1)", comment: "A chapter of an audiobook with no name"), 0, mark.startSeconds, max(0, end - mark.startSeconds))
            }
        }
        return parts.enumerated().map { ($0.element.displayTitle, $0.offset, 0, Double($0.element.runTimeTicks ?? 0) / 10_000_000) }
    }

    var body: some View {
        Group {
            if narrow {
                ScrollView {
                    VStack(spacing: 18) {
                        cover
                        about(centred: true)
                        buttons
                        chapterList
                    }
                    .padding(.horizontal, Theme.pageMargin)
                    .padding(.vertical, 20)
                }
            } else {
                HStack(alignment: .top, spacing: 56) {
                    VStack(alignment: .leading, spacing: 22) {
                        cover
                        about(centred: false)
                        buttons
                    }
                    .frame(width: coverSide)
                    .tvFocusSection()
                    ScrollView {
                        chapterList
                            .padding(.vertical, 30)
                            .padding(.horizontal, 10)
                    }
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
        .task(id: route) { await load() }
        // Listened to meanwhile: where it carries on from is somewhere else,
        // once the server has heard where it stopped.
        .background(PlayerStopped { item in
            guard item == nil || parts.contains(where: { $0.id == item?.id }) else { return }
            Task {
                try? await Task.sleep(for: .seconds(1))
                await load()
            }
        })
        .onChange(of: app.audiobookRevision) { _, _ in Task { await load() } }
    }

    private var cover: some View {
        Group {
            if let first {
                // A book in parts has its folder's cover, which the part borrows.
                BookCover(item: first, maxWidth: 800)
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
            Text(String(localized: "AUDIOBOOK", comment: "Above an audiobook's name, in capitals"))
                .font(.app(13, .heavy))
                .kerning(1.6)
                .foregroundStyle(Theme.primary.1)
            Text(title)
                .font(.app(Theme.isPhone ? 28 : 34, .bold))
                .multilineTextAlignment(centred ? .center : .leading)
                .lineLimit(3)
            if let author = first?.byLine {
                Text(author)
                    .font(.app(Theme.isPhone ? 18 : 22, .medium))
            }
            if loaded {
                Text(facts)
                    .font(.app(16))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(centred ? .center : .leading)
            }
            if let overview = first?.overview, !overview.isEmpty {
                ExpandableText(text: overview, lines: 3, maxWidth: 900)
            }
        }
        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
    }

    /// "2021 · 5 hr 12 min · 3 hr 4 min left".
    private var facts: String {
        let total = parts.compactMap(\.runTimeTicks).reduce(0, +)
        var bits = [first?.productionYear.map(String.init), Audiobooks.length(Double(total) / 10_000_000)].compactMap { $0 }
        if Audiobooks.isFinished(parts) {
            bits.append(String(localized: "Finished", comment: "An audiobook listened to the end"))
        } else if Audiobooks.isStarted(parts) {
            bits.append(String(localized: "\(Audiobooks.length(Audiobooks.secondsLeft(parts))) left", comment: "How much of an audiobook is still to listen to; the placeholder is a length like 3 hr 4 min"))
        }
        return bits.joined(separator: " · ")
    }

    private var buttons: some View {
        let started = Audiobooks.isStarted(parts) && !Audiobooks.isFinished(parts)
        return VStack(alignment: narrow ? .center : .leading, spacing: 16) {
            HStack(spacing: 14) {
                Button { play() } label: {
                    Label(started ? String(localized: "Resume") : String(localized: "Play"), systemImage: "play.fill")
                        .frame(minWidth: CGFloat(narrow ? 110 : 120).scaled)
                }
                .buttonStyle(GradientButtonStyle())
                .focused($playFocused)
                .disabled(parts.isEmpty)
            }
            HStack(spacing: 14) {
                // In the row of icons: beside Resume it had no room for its words.
                if started {
                    Button { play(from: 0, at: 0) } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.action(active: false))
                    .accessibilityLabel(String(localized: "From the Start", comment: "Plays an audiobook from its beginning"))
                }
                let finished = Audiobooks.isFinished(parts)
                Button { mark(finished: !finished) } label: {
                    Image(systemName: finished ? "checkmark.circle.fill" : "checkmark.circle")
                }
                .buttonStyle(.action(active: finished))
                .accessibilityLabel(finished ? String(localized: "Mark as Not Finished", comment: "An audiobook: marks it not listened to")
                                             : String(localized: "Mark as Finished", comment: "An audiobook's long press: marks every part of it listened to"))
                if let first { MusicFavoriteButton(item: first) }
                #if !os(tvOS)
                // Kept on the device, to listen without the server.
                DownloadGroupButton(id: route.id + (route.name.map { "|" + $0 } ?? ""), kind: .book, name: title,
                                    byLine: first?.byLine, pageId: route.id, items: parts, art: first)
                #endif
            }
        }
    }

    @ViewBuilder
    private var chapterList: some View {
        if !loaded {
            ProgressView().frame(maxWidth: .infinity, minHeight: 200)
        } else {
            // Lazy: a long book has a hundred chapters and more.
            LazyVStack(alignment: .leading, spacing: 2) {
                Text(parts.count > 1 ? String(localized: "Parts", comment: "Heading over an audiobook's files")
                                     : String(localized: "Chapters", comment: "Heading over an audiobook's chapters"))
                    .font(.app(15, .heavy))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.leading, 14)
                    .padding(.bottom, 6)
                ForEach(Array(chapters.enumerated()), id: \.offset) { place, chapter in
                    Button { play(from: chapter.part, at: chapter.start) } label: {
                        HStack(spacing: CGFloat(16).scaled) {
                            Text("\(place + 1)")
                                .font(.app(18, .semibold))
                                .monospacedDigit()
                                .opacity(0.6)
                                .frame(width: CGFloat(36).scaled)
                            Text(chapter.title)
                                .font(.app(20, .semibold))
                                .lineLimit(1)
                            if parts.count > 1, parts[chapter.part].userData?.played == true {
                                Image(systemName: "checkmark")
                                    .font(.app(14, .bold))
                                    .opacity(0.6)
                            }
                            Spacer(minLength: 12)
                            Text(NowPlayingProgress.time(chapter.length))
                                .font(.app(17))
                                .monospacedDigit()
                                .opacity(0.6)
                        }
                    }
                    .buttonStyle(TrackRowStyle())
                }
            }
        }
    }

    private func load() async {
        let askedAt = Date()
        guard let client = app.client, let found = try? await Audiobooks.parts(of: route, client: client) else {
            loaded = true
            return
        }
        MusicFavorites.shared.heard(found, askedAt: askedAt)
        let places = Self.places(found)
        if loaded { app.holdMenuFocus() }
        parts = found
        chapters = places
        loaded = true
    }

    private func play(from part: Int? = nil, at seconds: Double = 0) {
        guard let client = app.client, !parts.isEmpty else { return }
        Audiobooks.play(parts, title: title, from: part, at: seconds, client: client)
    }

    private func mark(finished: Bool) {
        guard let client = app.client else { return }
        let ids = parts.map(\.id)
        Task {
            for id in ids { try? await client.setPlayed(id, finished) }
            app.userDataChanged(audiobooks: true)
        }
    }
}
