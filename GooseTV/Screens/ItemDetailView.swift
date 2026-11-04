import SwiftUI

struct ItemDetailView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.sectionNavigator) private var navigator
    @Environment(\.displayScale) private var displayScale
    /// A phone's width: the opener stacks rather than sitting side by side.
    @Environment(\.isNarrow) private var narrow
    let itemId: String

    /// The page's width, measured: an iPad held upright (or sharing its
    /// screen) is too narrow for the opener's two columns side by side, though
    /// it isn't a phone's width.
    @State private var pageWidth: CGFloat = 0
    /// And its height: an iPad on its side is shorter than the opener the
    /// television has.
    @State private var pageHeight: CGFloat = 0
    /// Whether the opener stacks its two columns: a phone, or a page too
    /// narrow for both. Narrower than this and the details line pushed the
    /// whole page wider than the screen, its left edge under the menu.
    private var stacked: Bool {
        #if !os(tvOS)
        narrow || (pageWidth > 0 && pageWidth < 1060)
        #else
        narrow
        #endif
    }

    /// The buttons' column beside the details. An iPad's has room for six of
    /// its round buttons: at the television's width the fifth was cut in
    /// half at the column's edge.
    private static var actionsWidth: CGFloat {
        #if !os(tvOS)
        CGFloat(560).scaled
        #else
        CGFloat(440).scaled
        #endif
    }

    @State private var item: BaseItem?
    /// What heads the page of a recording, which has no backdrop of its own.
    @State private var cover: RecordingCover?
    /// Whether the page is complete enough to show: the item, and for a show
    /// the episode Play starts. Until then the spinner keeps hold of focus.
    @State private var ready = false
    /// The item couldn't be fetched, so there's nothing to show but a way to
    /// try again.
    @State private var loadFailed = false
    @FocusState private var retryFocused: Bool
    @State private var seasons: [BaseItem] = []
    @State private var selectedSeasonId: String?
    @State private var episodes: [BaseItem] = []
    /// On a show, the episode to carry on with, from any season.
    @State private var seriesNext: BaseItem?
    /// The episode after the one Play starts, for the skip-ahead button.
    @State private var followingEpisode: BaseItem?
    @State private var playingItem: BaseItem?
    /// The trailer kept on the server for this title, where there is one.
    @State private var localTrailer: BaseItem?
    @State private var playingFromBeginning = false
    /// What plays after `playingItem`, for Shuffle.
    @State private var playingQueue: [BaseItem] = []
    /// Which version to play, for a film kept in more than one.
    @State private var chosenSourceId: String?
    @State private var playedOverride: Bool?
    @State private var favoriteOverride: Bool?
    @State private var watchlistOverride: Bool?
    @State private var similar: [BaseItem] = []
    @State private var extras: [BaseItem] = []
    /// Whether More Like This and Extras have been fetched: once is enough,
    /// and a film with none isn't asked again every time a mark changes.
    @State private var shelvesFetched = false
    /// The reload a change of watched marks or position started. One at a
    /// time: an older one landing after a newer one put back what the newer
    /// one replaced, the eye or the star with it.
    @State private var reloadTask: Task<Void, Never>?
    /// The account's change count (`AppState.userDataRevision`) the page was
    /// last read at: the player's close bumps it while the player still
    /// covers the page, and a page under a cover missed the change.
    @State private var loadedRevision = -1
    /// Moves on each time the page stores what it read. An item read again
    /// is the same item to SwiftUI (`BaseItem` is equal by its id), so
    /// storing it redrew nothing: back from the player, the page had the
    /// new position and still said Play.
    @State private var itemVersion = 0
    /// A button in the opener to put focus on (Play, as the page opens).
    @State private var headerFocusRequest: HeaderControl?
    /// An episode for the row to put focus on, when picking ends from its bar.
    @State private var episodeFocusRequest: String?

    enum HeaderControl: Hashable { case play, restart, watched, favorite, watchlist, trailer, next, shuffle }
    /// The episodes picked to mark together; nil when not picking.
    @State private var selection: Set<String>?
    /// Watched marks just sent, shown until the episodes reload.
    @State private var episodePlayed: [String: Bool] = [:]
    #if !os(tvOS)
    /// Why a season's download from an episode's menu didn't start.
    @State private var downloadProblem: String?
    #endif

    var body: some View {
        Group {
            if let item, ready {
                content(for: item)
            } else if loadFailed {
                failure
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // Without something focusable here, focus escapes to the menu
                    // while the page loads, which pops the sidebar open.
                    .focusable()
            }
        }
        #if !os(tvOS)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            pageWidth = size.width
            pageHeight = size.height
        }
        #endif
        .task {
            // The page arrives as a spinner that is swapped for the header once
            // the item loads. Focus let go in between fell to the menu, which
            // opened it; held shut, it lands on the page, and then on Play.
            app.holdMenuFocus()
            await load()
        }
        // The shelves at the foot of the page, apart: Play and focus don't
        // wait on them (similar titles are often the server's slowest answer).
        .task { await loadShelves() }
        // The title's theme song while the page is up, and its trailer.
        .task(id: item?.id) {
            guard let item, let client = app.client else { return }
            ThemeMusic.shared.play(for: item, client: client)
            if (item.localTrailerCount ?? 0) > 0 { localTrailer = await client.localTrailers(of: item.id).first }
        }
        .onDisappear { ThemeMusic.shared.leave(itemId) }
        .playerCover(item: $playingItem) { playItem in
            PlayerView(item: playItem, mediaSourceId: sourceId(for: playItem),
                       fromBeginning: playingFromBeginning, queue: playingQueue)
        }
        .onChange(of: playingItem) { _, newValue in
            // The page reloads when the player announces its close (below),
            // and catches up here if that went by while it was covered.
            if newValue == nil {
                playingFromBeginning = false
                playingQueue = []
                Task { await catchUp() }
            }
        }
        // A show come to from among the server's recordings: its episodes
        // are recordings, and a long press on one offers to delete it.
        .environment(\.recordingsDeletable, app.recordedShows.contains(itemId))
        .onChange(of: app.userDataRevision) { _, _ in reloadForChange() }
        // What Play starts, worked out while the page is read (see PlaybackPrep).
        .task(id: "\(ready)|\(prepTarget?.id ?? "")|\(chosenSourceId ?? "")") {
            guard ready, let target = prepTarget, let client = app.client else { return }
            #if !os(tvOS)
            if Downloads.shared.fileURL(target.id) != nil { return }
            #endif
            PlaybackPrep.shared.prepare(target, mediaSourceId: sourceId(for: target), client: client)
        }
        #if !os(tvOS)
        .alert(downloadProblem ?? "", isPresented: $downloadProblem.isPresent()) {}
        #endif
    }

    /// The trailer: the one on the server, played here; else the one on
    /// YouTube, in the YouTube app. Nil where there's neither.
    private func trailerAction(for item: BaseItem) -> (() -> Void)? {
        if let localTrailer {
            return {
                playingFromBeginning = true
                playingItem = localTrailer
            }
        }
        guard let url = Trailers.youTube(item.remoteTrailers) else { return nil }
        return {
            ThemeMusic.shared.stop()
            UIApplication.shared.open(url)
        }
    }

    /// The version picked belongs to this page's item. Anything else it plays
    /// (the next episode, an extra, a shuffled episode) plays its own: asked
    /// for another item's version, the server has no stream to give.
    private func sourceId(for target: BaseItem) -> String? {
        target.id == item?.id ? chosenSourceId : nil
    }

    /// The item couldn't be fetched: say so, with a way to try again, rather
    /// than a spinner that never stops.
    private var failure: some View {
        VStack(spacing: 24) {
            Text(String(localized: "Couldn't load this from the server.",
                        comment: "Shown where a page or a setting couldn't be fetched, above a Try Again button"))
                .font(.app(24, .semibold))
                .multilineTextAlignment(.center)
            Button(String(localized: "Try Again")) { retry() }
                .buttonStyle(.pill(selected: true))
                .focused($retryFocused)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            // Focus was on the spinner, which has gone: onto the button, not the menu.
            try? await Task.sleep(for: .milliseconds(60))
            retryFocused = true
        }
    }

    private func retry() {
        app.holdMenuFocus()
        loadFailed = false
        Task { await load() }
        Task { await loadShelves() }
    }

    @ViewBuilder
    private func content(for item: BaseItem) -> some View {
        ScrollViewReader { proxy in
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 30) {
                Color.clear.frame(height: 0).id("detail-top")

                header(for: item) {
                    // Back up to the header controls brings the whole opener
                    // back into view.
                    withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo("detail-top", anchor: .top) }
                }

                if item.isSeries {
                    seasonSection
                }

                // Each row a region of its own: a press down from anywhere
                // above lands in it, whatever lies straight under the press
                // (from the plot's MORE, a season on the right, a later
                // episode, it found nothing, or skipped a row).
                CastShelf(people: item.people ?? [])
                    .tvFocusSection()

                if !extras.isEmpty {
                    Shelf(title: String(localized: "Extras"), eyebrow: String(localized: "Trailers and behind the scenes"),
                          accent: Theme.palette[0]) {
                        ForEach(extras) { extra in
                            LandscapeCard(item: extra) { playingItem = extra }
                        }
                    }
                    .tvFocusSection()
                }

                if !similar.isEmpty {
                    SimilarShelf(items: similar)
                        .tvFocusSection()
                }
            }
            .padding(.horizontal, narrow ? 20 : 40)
            .padding(.bottom, 60)
        }
        .pageSides()
        // Back ends picking episodes before it leaves the page.
        .tvExitCommand(perform: selection == nil ? nil : { endSelection() })
        }
        .background(alignment: .top) {
            // Whatever has to be cut to fit, it's the foot of the picture,
            // never the top: that's where people's heads are.
            Group {
                if let cover, cover.title != nil {
                    // A recording of a show the library has: the show's own backdrop.
                    RemoteImage(url: cover.url, alignment: .top)
                } else if let cover {
                    // A recording: its cover again, out of focus, where a
                    // film's backdrop would be.
                    RemoteImage(url: cover.url).blur(radius: 60)
                } else {
                    // About 2000 points across once it bleeds past the edge, so the
                    // screen's own pixels are asked for, not a smaller picture stretched.
                    RemoteImage(url: app.client?.imageURL(for: item, type: "Backdrop",
                                                          maxWidth: Theme.pixels(2000, scale: displayScale)),
                                alignment: .top)
                }
            }
                .frame(height: Self.backdropHeight)
                .frame(maxWidth: .infinity)
                .clipped()
                .overlay(Color.black.opacity(0.25))
                #if os(tvOS)
                // The page starts beside the menu's icons, which sit on the bare
                // wallpaper: the picture's left edge fades into it rather than
                // standing as a hard line down the screen.
                .overlay(alignment: .leading) {
                    LinearGradient(colors: [Theme.background, .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: 180)
                }
                #endif
                // Fade out to transparent so the backdrop melts into the wallpaper.
                .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                             .init(color: .black.opacity(0.7), location: 0.55),
                                             .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                // Bleeds past the right edge so no strip of wallpaper shows
                // there. Last, after the clip and the fades, which would
                // otherwise cut the bleed off again at the page's own edge
                // (they did: a dark strip ran down the screen's right side).
                .padding(.trailing, -80)
                .ignoresSafeArea()
                .overlay(alignment: stacked ? .top : .topTrailing) {
                    if let cover, cover.title == nil { coverCard(cover) }
                }
        }
        .task(id: item.id) { cover = await app.recordingCover(for: item) }
    }

    /// How tall the picture behind the page is. On a television, the
    /// screen's whole height: at 880 a widescreen picture, drawn the width
    /// of the screen, lost its top and its foot to fit (a newsreader's head),
    /// and the screen's last 200 points had no picture at all.
    private static var backdropHeight: CGFloat {
        #if os(tvOS)
        1080
        #else
        Theme.isPhone ? 560 : 880
        #endif
    }

    /// The cover itself, whole, over the top of the page: beside the opener
    /// where there's room, above it where the page is a column.
    private func coverCard(_ cover: RecordingCover) -> some View {
        #if os(tvOS)
        let width: CGFloat = 600
        #else
        // Small enough in a column to end above the title, which sits low.
        let width: CGFloat = stacked ? 240 : 400
        #endif
        return RemoteImage(url: cover.url)
            .frame(width: width, height: width / cover.shape)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 14)
            .padding(.top, stacked ? 8 : 96)
            .padding(.trailing, stacked ? 0 : 80)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func header(for item: BaseItem, entered: @escaping () -> Void) -> some View {
        // Infuse-style opener anchored low: logo + actions on the left,
        // plot / metadata / ratings in a column beside them.
        let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 28))
                            : AnyLayout(HStackLayout(alignment: .bottom, spacing: 48))
        layout {
            DetailActions(item: item, version: itemVersion, logoOf: cover?.title,
                          playTarget: item.isSeries ? nextEpisodeToPlay : item,
                          following: followingEpisode,
                          isPlayed: isPlayed,
                          isFavorite: isFavorite,
                          isWatchlisted: watchlistable(item) ? isWatchlisted : nil,
                          focusRequest: $headerFocusRequest,
                          entered: entered,
                          play: { target, fromBeginning in
                              playingFromBeginning = fromBeginning
                              playingItem = target
                          },
                          toggleWatched: { Task { await togglePlayed(item) } },
                          toggleFavorite: { Task { await toggleFavorite(item) } },
                          toggleWatchlist: { Task { await toggleWatchlist(item) } },
                          shuffle: { Task { await shuffle(item) } },
                          trailer: trailerAction(for: item))
                .frame(maxWidth: stacked ? .infinity : Self.actionsWidth, alignment: .leading)
            infoColumn(for: item)
                .frame(maxWidth: .infinity, alignment: .leading)
                // One section, so right from Play gets in even though the
                // studio pills sit lower than it; down then reaches them.
                .tvFocusSection()
        }
        // On a phone the picture shows above the opener rather than behind it.
        .frame(maxWidth: .infinity, minHeight: headerHeight(for: item), alignment: .bottomLeading)
    }

    /// How far down the opener reaches, its foot being where it ends. On the
    /// TV, high enough for the row under it to show; with no row known to
    /// follow when the page opens (no seasons, no cast: a recording, mostly),
    /// nearer the foot of the screen than over an empty band. Similar titles
    /// and extras arrive later, and don't move it: they're a scroll away.
    private func headerHeight(for item: BaseItem) -> CGFloat {
        if narrow { return 560 }
        #if os(tvOS)
        if !item.isSeries, CastShelf.listed(item.people ?? []).isEmpty { return 860 }
        return 780
        #else
        // Within the screen: on an iPad on its side (834 tall) the opener's
        // foot, its buttons and the plot beside them, fell past the bottom.
        return pageHeight > 0 ? min(780, pageHeight - 40) : 780
        #endif
    }

    private func shuffle(_ show: BaseItem) async {
        guard let episodes = try? await app.client?.playQueue(for: show, shuffled: true),
              let first = episodes.first else { return }
        playingQueue = Array(episodes.dropFirst())
        playingItem = first
    }

    @ViewBuilder
    private func infoColumn(for item: BaseItem) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // The film's tagline, over its plot, as a poster has it.
            if let tagline = item.taglines?.first?.trimmingCharacters(in: .whitespaces), !tagline.isEmpty {
                Text(tagline)
                    .font(.custom("Figtree-Italic", fixedSize: 26 * Theme.uiScale))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let overview = item.overview, !overview.isEmpty {
                ExpandableText(text: overview, lines: 3)
            }

            // Who made it ends the line: a show's network after its status, a
            // film's studios after its director, each a way into everything
            // else of theirs. As many as fit, and always the first.
            let studios = Array((item.studios ?? []).prefix(3))
            Group {
                if stacked {
                    // All of it, a swipe along.
                    metadataLine(item: item, studios: studios)
                        .scrollsSideways(true)
                } else {
                    ViewThatFits(in: .horizontal) {
                        ForEach(Array(stride(from: studios.count, through: min(studios.count, 1), by: -1)), id: \.self) { count in
                            metadataLine(item: item, studios: Array(studios.prefix(count)))
                        }
                    }
                }
            }
            .tvFocusSection()

            if let media = MediaSummary(chosenSource(of: item) ?? item.mediaSources?.first) {
                MediaBadges(summary: media)
                    .scrollsSideways(stacked)
            }

            // A film kept in more than one version — a remux beside a smaller
            // encode — so the badges above and the stream both follow the pick.
            if let sources = item.mediaSources, sources.count > 1 {
                VStack(alignment: .leading, spacing: 10) {
                    Text("VERSION")
                        .font(.app(12, .heavy))
                        .kerning(1.4)
                        .foregroundStyle(Theme.textSecondary)
                    HStack(spacing: 10) {
                        ForEach(Array(sources.enumerated()), id: \.offset) { index, source in
                            Button(source.name ?? String(localized: "Version \(index + 1)", comment: "Name for an unnamed copy of a film, numbered")) {
                                chosenSourceId = source.id
                            }
                            .buttonStyle(.pill(selected: source.id == (chosenSourceId ?? sources.first?.id)))
                        }
                    }
                }
                .tvFocusSection()
            }

            HStack(spacing: 10) {
                if let genres = item.genres {
                    ForEach(Array(genres.prefix(4).enumerated()), id: \.offset) { index, genre in
                        TagChip(text: genre, colors: Theme.palette[index % Theme.palette.count])
                    }
                }
                if let critic = item.criticRating {
                    ScoreBadge(label: String(localized: "Critics", comment: "Label beside the critics' score"), value: String(localized: "\(critic)%", comment: "Critics' score as a percentage"),
                               colors: critic >= 60 ? Theme.palette[2] : Theme.palette[1])
                }
            }
            .scrollsSideways(stacked)
        }
    }

    private func metadataLine(item: BaseItem, studios: [Studio]) -> some View {
        HStack(spacing: 16) {
            MetadataRow(item: item)
            if item.isSeries, let status = item.status {
                Text(ServerWords.seriesStatus(status))
                    .font(.app(18))
                    .foregroundStyle(status == "Continuing" ? .green : Theme.textSecondary)
            }
            if let director = item.people?.first(where: { $0.type == "Director" })?.name {
                Text("Dir. \(director)", comment: "Short for Director, before a person's name")
                    .font(.app(18))
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(studios) { studio in
                Button {
                    navigator.showStudio(studio)
                } label: {
                    Label(studio.name, systemImage: item.isSeries ? "tv" : "building.2")
                        .lineLimit(1)
                }
                .buttonStyle(.studio)
                .accessibilityHint(String(localized: "Shows everything else from \(studio.name)"))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// The version picked, if the viewer picked one.
    private func chosenSource(of item: BaseItem) -> MediaSource? {
        guard let id = chosenSourceId else { return nil }
        return item.mediaSources?.first { $0.id == id }
    }

    private var isPlayed: Bool { playedOverride ?? item?.userData?.played ?? false }
    private var isFavorite: Bool { favoriteOverride ?? item?.userData?.isFavorite ?? false }
    /// Marked for the watchlist, whether or not it's been watched since.
    private var isMarked: Bool { watchlistOverride ?? (item?.userData?.likes == true) }
    /// On the watchlist: marked for it, and not yet watched.
    private var isWatchlisted: Bool { isMarked && !isPlayed }

    /// The watchlist is of films to be watched: so the button is a film's,
    /// and not there for one that's been watched (which is what took it off).
    private func watchlistable(_ item: BaseItem) -> Bool {
        item.isMovie && (!isPlayed || isWatchlisted)
    }

    private func togglePlayed(_ item: BaseItem) async {
        let target = !isPlayed
        let listed = isMarked
        playedOverride = target
        do {
            try await app.client?.setPlayed(item.id, target)
            // Watched is off the watchlist, and for good: unwatching it
            // later doesn't put it back.
            if target, listed {
                try? await app.client?.setWatchlisted(item.id, false)
                watchlistOverride = false
            }
            // So the grids and shelves behind show it when this page closes.
            app.userDataChanged()
        } catch { playedOverride = !target }
    }

    private func toggleWatchlist(_ item: BaseItem) async {
        let target = !isWatchlisted
        watchlistOverride = target
        do {
            try await app.client?.setWatchlisted(item.id, target)
            // So the menu shows Watchlist only while there's something on it.
            app.userDataChanged(watchlist: true)
        } catch { watchlistOverride = !target }
    }

    private func toggleFavorite(_ item: BaseItem) async {
        let target = !isFavorite
        favoriteOverride = target
        do {
            try await app.client?.setFavorite(item.id, target)
            // So the screens behind show it, and the menu shows Favourites
            // only while there are any.
            app.userDataChanged(favorites: true)
        } catch { favoriteOverride = !target }
    }

    // MARK: Seasons / episodes

    @ViewBuilder
    private var seasonSection: some View {
        VStack(alignment: .leading, spacing: 24) {
            if seasons.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 20) {
                        ForEach(seasons) { season in
                            Button {
                                selectedSeasonId = season.id
                                Task { await loadEpisodes() }
                            } label: {
                                Text(season.displayTitle)
                            }
                            .buttonStyle(.pill(selected: selectedSeasonId == season.id))
                            // Mark a whole season watched or unwatched.
                            .itemContextMenu(season)
                        }
                    }
                    .padding(.vertical, 20)
                }
                .tvFocusSection()
            }

            EpisodeRow(episodes: episodes, version: itemVersion,
                       seasonTitle: seasons.first(where: { $0.id == selectedSeasonId })?.displayTitle
                           ?? String(localized: "Episodes"),
                       played: episodePlayed,
                       selection: selection,
                       focusRequest: $episodeFocusRequest,
                       menuActions: episodeMenus()) { episode in
                if selection != nil {
                    toggleSelected(episode.id)
                } else {
                    playingItem = episode
                }
            }
            .tvFocusSection()

            if let selection {
                selectionBar(selection)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: selection == nil)
    }

    // MARK: Picking episodes

    /// Each episode's menu rows, worked out as its menu opens: on an iPhone
    /// or iPad they depend on what has been downloaded since the page drew.
    private func episodeMenus() -> (BaseItem, Int) -> [ItemMenuAction] {
        #if !os(tvOS)
        return { episode, index in
            episodeMenuActions(for: episode, at: index) + seasonDownloadActions(for: episode)
        }
        #else
        return { episode, index in episodeMenuActions(for: episode, at: index) }
        #endif
    }

    /// The episode menu's own rows: start picking, and mark everything up to here.
    private func episodeMenuActions(for episode: BaseItem, at index: Int) -> [ItemMenuAction] {
        var actions = [ItemMenuAction(title: String(localized: "Select Episodes"), icon: "checklist") {
            selection = [episode.id]
        }]
        if index > 0 {
            let earlier = episodes[..<index].map(\.id)
            actions.append(.init(title: String(localized: "Mark Earlier Episodes as Watched"), icon: "text.badge.checkmark") {
                Task { await setPlayed(earlier, true) }
            })
        }
        return actions
    }

    #if !os(tvOS)
    /// Download the whole season, while an episode of it besides this one
    /// isn't downloaded. The episode itself is the long-press menu's own
    /// row, as on any card. Which episodes is decided when it's chosen.
    private func seasonDownloadActions(for episode: BaseItem) -> [ItemMenuAction] {
        let downloads = Downloads.shared
        guard let client = app.client as? MediaBrowserClient,
              episodes.contains(where: { $0.id != episode.id && downloads.record($0.id) == nil }) else { return [] }
        let season = episodes
        return [.init(title: String(localized: "Download Season"), icon: "square.and.arrow.down.on.square") {
            Task {
                for next in season where downloads.record(next.id) == nil {
                    // Stops at the first that can't start (no space, no server).
                    if let problem = await downloads.download(next, client: client) {
                        downloadProblem = problem
                        break
                    }
                }
            }
        }]
    }
    #endif

    private func toggleSelected(_ id: String) {
        guard var picked = selection else { return }
        if picked.remove(id) == nil { picked.insert(id) }
        selection = picked
    }

    /// Stops picking. Focus goes back to the episodes: from the bar, which then
    /// goes, it would otherwise go up to Play.
    private func endSelection(focusing id: String? = nil) {
        let back = id ?? episodes.first { selection?.contains($0.id) == true }?.id ?? episodes.first?.id
        selection = nil
        guard let back else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(60))
            episodeFocusRequest = back
        }
    }

    /// Under the episodes while picking: what's picked, and what to do with it.
    private func selectionBar(_ picked: Set<String>) -> some View {
        let all = picked.count == episodes.count
        return HStack(spacing: 16) {
            Text(picked.count == 1 ? String(localized: "1 episode selected")
                                   : String(localized: "\(picked.count) episodes selected"))
                .font(.app(20, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .padding(.trailing, 12)
            Button {
                Task { await markSelection(true) }
            } label: {
                Label(String(localized: "Mark as Watched"), systemImage: "eye")
            }
            .disabled(picked.isEmpty)
            Button {
                Task { await markSelection(false) }
            } label: {
                Label(String(localized: "Mark as Unwatched"), systemImage: "eye.slash")
            }
            .disabled(picked.isEmpty)
            Button(all ? String(localized: "Select None") : String(localized: "Select All")) {
                selection = all ? [] : Set(episodes.map(\.id))
            }
            Button(String(localized: "Done")) { endSelection() }
        }
        .buttonStyle(.pill(selected: false))
        .tvFocusSection()
        .padding(.horizontal, 4)
        .scrollsSideways(narrow)
    }

    private func markSelection(_ played: Bool) async {
        guard let picked = selection, !picked.isEmpty else { return }
        // In the order they're on screen, so the server's Next Up follows along.
        let ids = episodes.map(\.id).filter(picked.contains)
        endSelection(focusing: ids.last)
        await setPlayed(ids, played)
    }

    /// Marks episodes all at once, showing it at once; any the server refuses
    /// go back to how they were.
    private func setPlayed(_ ids: [String], _ played: Bool) async {
        guard let client = app.client, !ids.isEmpty else { return }
        for id in ids { episodePlayed[id] = played }
        let failed = await withTaskGroup(of: String?.self) { group in
            for id in ids {
                group.addTask { (try? await client.setPlayed(id, played)) == nil ? id : nil }
            }
            var failed: [String] = []
            for await id in group { if let id { failed.append(id) } }
            return failed
        }
        for id in failed { episodePlayed[id] = nil }
        if failed.count < ids.count { app.userDataChanged() }
    }

    /// What Play would start: the film, or a show's next episode.
    private var prepTarget: BaseItem? {
        guard let item else { return nil }
        if item.isSeries { return nextEpisodeToPlay }
        return item.isContainer ? nil : item
    }

    /// The server's answer, which spans every season; the season on screen is
    /// only a fallback, for a show with nothing watched or a server that
    /// didn't say.
    private var nextEpisodeToPlay: BaseItem? {
        seriesNext ?? episodes.first { !($0.userData?.played ?? false) } ?? episodes.first
    }

    // MARK: Loading

    /// The item, and for a show its seasons and episodes: what the opener and
    /// Play need. The shelves at the foot of the page load on their own.
    /// Watched marks or a position moved: read again. A preparation made
    /// before would start in the wrong place.
    private func reloadForChange() {
        PlaybackPrep.shared.forget()
        reloadTask?.cancel()
        reloadTask = Task { await load(force: true) }
    }

    /// Back from the player: the position it reported reaches the server
    /// and the account's count moves a moment after the cover goes. Waits
    /// for that (a few seconds at most), then reads the page again if the
    /// change wasn't already taken in.
    private func catchUp() async {
        for _ in 0..<16 where app.userDataRevision == loadedRevision {
            try? await Task.sleep(for: .milliseconds(250))
        }
        if app.userDataRevision != loadedRevision { reloadForChange() }
    }

    private func load(force: Bool = false) async {
        guard let client = app.client, item == nil || force else { return }
        let opening = item == nil
        let revision = app.userDataRevision
        let fetched = try? await client.item(id: itemId)
        // A newer reload has started meanwhile, or the page has gone: that
        // one's answer is the one to keep.
        guard !Task.isCancelled else { return }
        if let fetched {
            item = fetched
            loadedRevision = revision
            itemVersion += 1
            // The server's word from here on, which may have moved since: an
            // episode unwatched makes the show unwatched.
            playedOverride = nil
            favoriteOverride = nil
            watchlistOverride = nil
            if opening { similar = withoutCopies(similar) }
        } else if opening {
            loadFailed = true
            return
        }
        // A refetch that fails keeps the page it has instead of blanking it.
        if item?.isSeries == true {
            // Together. Both are awaited, in the order declared, on every path,
            // which is what keeps an async let safe here.
            async let fetchedSeasons = try? await client.seasons(seriesId: itemId)
            async let fetchedNext = client.nextEpisode(seriesId: itemId)
            let seasonList = await fetchedSeasons
            let next = await fetchedNext
            guard !Task.isCancelled else { return }
            if let seasonList { seasons = seasonList }
            seriesNext = next
            itemVersion += 1
            // Open on the season being watched, not always the first.
            if selectedSeasonId == nil {
                // A show of recordings: the newest, where the server numbers
                // its seasons by year. A show watched in order: where it's got to.
                let newest = seasons.max { ($0.indexNumber ?? -1) < ($1.indexNumber ?? -1) }
                selectedSeasonId = app.recordedShows.contains(itemId) ? newest?.id ?? seasons.first?.id
                    : seriesNext?.seasonId.flatMap { id in seasons.first { $0.id == id }?.id } ?? seasons.first?.id
            }
            await loadEpisodes()
            guard !Task.isCancelled else { return }
        }
        // After the episode list, which is what Play falls back on for a show.
        let playTarget = item?.isSeries == true ? nextEpisodeToPlay : (item?.isEpisode == true ? item : nil)
        if opening, item != nil {
            ready = true
            await focusPlay()
        }
        if let playTarget {
            followingEpisode = try? await client.nextEpisode(after: playTarget)
        } else {
            followingEpisode = nil
        }
    }

    /// More Like This and Extras, once. Separate calls, made together.
    /// A task group rather than async let: async lets awaited only on some
    /// paths aborted the app on device ("freed pointer was not the last
    /// allocation") the moment a detail page opened.
    private func loadShelves() async {
        guard let client = app.client, !shelvesFetched else { return }
        enum Fetched {
            case similar([BaseItem]?), extras([BaseItem])
        }
        let itemId = itemId
        await withTaskGroup(of: Fetched.self) { group in
            group.addTask { .similar(try? await client.similar(to: itemId, limit: 24)) }
            group.addTask { .extras(await client.extras(for: itemId)) }
            for await result in group {
                switch result {
                case .similar(let fetched):
                    similar = withoutCopies(fetched ?? [])
                    // Asked again the next time the page appears if the server
                    // didn't answer (and at once, by a retry of the page).
                    shelvesFetched = fetched != nil
                case .extras(let fetched):
                    extras = fetched
                }
            }
        }
    }

    /// A film kept in two libraries (a 1080p copy and a 4K one) is two items
    /// to the server, so it came back twice, and this film's other copy came
    /// back as similar to itself. One of each, and not this one.
    private func withoutCopies(_ items: [BaseItem]) -> [BaseItem] {
        var seen: Set<String> = item.map { [$0.titleAndYear] } ?? []
        return items.filter { seen.insert($0.titleAndYear).inserted }
    }

    /// Puts focus on Play once the header is on screen, keeping the menu shut
    /// meanwhile. Only on first opening: a refresh leaves focus where it is.
    /// A show's Play waits on its episodes, which is why this comes after them.
    private func focusPlay() async {
        app.holdMenuFocus()
        // A beat for the header to be laid out, or there's nothing to focus.
        try? await Task.sleep(for: .milliseconds(60))
        guard !Task.isCancelled else { return }
        let hasPlay = item?.isSeries == true ? nextEpisodeToPlay != nil : item != nil
        headerFocusRequest = hasPlay ? .play : .watched
    }

    private func loadEpisodes() async {
        guard let client = app.client, let seasonId = selectedSeasonId else { return }
        let fetched = try? await client.episodes(seriesId: itemId, seasonId: seasonId)
        // Another season was picked while this one was on its way, or a newer
        // reload has started: theirs is the answer to show.
        guard seasonId == selectedSeasonId, !Task.isCancelled else { return }
        guard let fetched else {
            // Failed: the episodes shown stay if they're this season's, but
            // another season's would sit under the wrong pill.
            if episodes.first?.seasonId != seasonId { episodes = [] }
            return
        }
        episodes = fetched
        itemVersion += 1
        // The stills, fetched ahead (see ImagePipeline.prefetch); the same
        // addresses EpisodeCard asks for.
        ImagePipeline.prefetch(episodes.compactMap { client.imageURL(for: $0, maxWidth: 800) })
        episodePlayed = [:]
        // A picked episode that's gone, or another season's, can't be marked.
        if let picked = selection { selection = picked.intersection(episodes.map(\.id)) }
    }
}

// MARK: - The opener's buttons

/// The title, Play, and the icon buttons under it. A view of its own, with
/// its own focus: which button is highlighted is read here (for the caption
/// under them) and nowhere else, so moving along the row redraws this column
/// rather than the whole page.
private struct DetailActions: View {
    typealias Control = ItemDetailView.HeaderControl
    @Environment(\.appState) private var app
    let item: BaseItem
    /// The page's count of reads (see `ItemDetailView.itemVersion`): the
    /// buttons redraw for a new position, which the item alone doesn't make.
    var version = 0
    /// Whose logo heads it, where not the item's own: a recording's show.
    var logoOf: BaseItem? = nil
    /// What Play starts: the film, or a show's next episode.
    let playTarget: BaseItem?
    /// The episode after that one, for the skip-ahead button.
    let following: BaseItem?
    let isPlayed: Bool
    let isFavorite: Bool
    /// Whether a film is on the watchlist; nil where there's no such button
    /// (a show, or a film already watched).
    let isWatchlisted: Bool?
    /// A button the page wants focus on (Play, as it opens); cleared once done.
    @Binding var focusRequest: Control?
    /// Focus has come to these buttons from elsewhere on the page.
    let entered: () -> Void
    /// Plays an item, from its beginning or not.
    let play: (BaseItem, Bool) -> Void
    let toggleWatched: () -> Void
    let toggleFavorite: () -> Void
    let toggleWatchlist: () -> Void
    let shuffle: () -> Void
    /// Plays the trailer; nil where it has none.
    let trailer: (() -> Void)?

    @FocusState private var focus: Control?
    /// Play ignores a press held long past a click.
    @State private var playPress = PressTimer()
    /// The list of TVs to play it on, while it's up.
    @State private var playingOnTV = false

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let logoURL = app?.client?.imageURL(for: logoOf ?? item, type: "Logo", maxWidth: 600) {
                HeroLogo(url: logoURL, fallback: item.displayTitle)
            } else {
                Text(item.displayTitle)
                    .font(.app(40, .bold))
                    .lineLimit(2)
            }

            if let playTarget {
                Button {
                    playPress.release { play(playTarget, false) }
                } label: {
                    Label(item.isSeries ? playLabel(for: playTarget)
                                        : (item.resumeTicks > 0 ? String(localized: "Resume") : String(localized: "Play")),
                          systemImage: "play.fill")
                        .frame(width: CGFloat(250).scaled)
                }
                .buttonStyle(GradientButtonStyle(timer: playPress))
                .focused($focus, equals: .play)

                #if !os(tvOS)
                // Played on an Apple TV instead, and worked from here (see
                // PlayOnSheet). A button of its own: in the row of icons it was
                // the last, and the first to run off a phone's screen.
                if app?.serverFlavor == .jellyfin {
                    Button { playingOnTV = true } label: {
                        Label(PlayOnSheet.title, systemImage: "tv")
                            .frame(width: CGFloat(250).scaled)
                    }
                    .buttonStyle(.pill(selected: false))
                    .sheet(isPresented: $playingOnTV) { PlayOnSheet(item: playTarget) }
                }
                #endif
            }

            HStack(spacing: 16) {
                Button(action: toggleWatched) {
                    Image(systemName: isPlayed ? "eye.fill" : "eye")
                }
                .buttonStyle(.action(active: isPlayed))
                .focused($focus, equals: .watched)
                .accessibilityLabel(isPlayed ? String(localized: "Mark as unwatched") : String(localized: "Mark as watched"))

                Button(action: toggleFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star")
                }
                .buttonStyle(.action(active: isFavorite))
                .focused($focus, equals: .favorite)
                .accessibilityLabel(isFavorite ? String(localized: "Remove from favourites") : String(localized: "Add to favourites"))

                if let isWatchlisted {
                    Button(action: toggleWatchlist) {
                        Image(systemName: isWatchlisted ? "bookmark.fill" : "bookmark")
                    }
                    .buttonStyle(.action(active: isWatchlisted))
                    .focused($focus, equals: .watchlist)
                    .accessibilityLabel(isWatchlisted ? String(localized: "Remove from watchlist") : String(localized: "Add to watchlist"))
                }

                if let trailer {
                    Button(action: trailer) {
                        Image(systemName: "film")
                    }
                    .buttonStyle(.action(active: false))
                    .focused($focus, equals: .trailer)
                    .accessibilityLabel(Trailers.title)
                }

                #if !os(tvOS)
                // To watch without the server: a film or an episode's own page;
                // a show's next episodes, kept on the device as they come up.
                if !item.isSeries && !item.isContainer {
                    DownloadButton(item: item)
                } else if item.isSeries {
                    KeepDownloadedButton(series: item)
                }
                #endif

                // Skips ahead past what Play starts, so it's there only when
                // there is an episode after it.
                if let following {
                    Button {
                        play(following, false)
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .buttonStyle(.action(active: false))
                    .focused($focus, equals: .next)
                    .accessibilityLabel(String(localized: "Play the next episode, \(following.spokenDescription)"))
                }

                // Every episode of the show in a random order, one after another.
                if item.isSeries {
                    Button(action: shuffle) {
                        Image(systemName: "shuffle")
                    }
                    .buttonStyle(.action(active: false))
                    .focused($focus, equals: .shuffle)
                    .accessibilityLabel(String(localized: "Shuffle all episodes"))
                }

                if let playTarget, playTarget.resumeTicks > 0 {
                    Button {
                        play(playTarget, true)
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                    }
                    .buttonStyle(.action(active: false))
                    .focused($focus, equals: .restart)
                    .accessibilityLabel(item.isSeries ? String(localized: "Play \(playTarget.spokenDescription) from the beginning")
                                                      : String(localized: "Play from the beginning"))
                }
            }
            .scrollsSidewaysOnPhone()

            // What the highlighted icon does. Its line is always there, so the
            // header doesn't shift as focus moves along the row.
            let caption = caption(for: focus)
            Text(caption ?? " ")
                .font(.app(17, .semibold))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .opacity(caption == nil ? 0 : 1)
                .animation(.easeOut(duration: 0.15), value: focus)
                .accessibilityHidden(true)   // each button already has its label
        }
        .onChange(of: focusRequest, initial: true) { _, request in
            guard let request else { return }
            focus = request
            focusRequest = nil
        }
        .onChange(of: focus) { old, new in
            if old == nil, new != nil { entered() }
        }
    }

    /// Words for the icon buttons under Play, which have none of their own.
    private func caption(for control: Control?) -> String? {
        let label = item.isSeries ? playTarget?.episodeLabel : nil
        switch control {
        case .restart:
            return label.map { String(localized: "Play \($0) from the beginning") } ?? String(localized: "Play from the beginning")
        case .watched:
            if item.isSeries {
                return isPlayed ? String(localized: "Mark every episode as unwatched") : String(localized: "Mark every episode as watched")
            }
            return isPlayed ? String(localized: "Mark as unwatched") : String(localized: "Mark as watched")
        case .favorite:
            return isFavorite ? String(localized: "Remove from favourites") : String(localized: "Add to favourites")
        case .watchlist:
            return isWatchlisted == true ? String(localized: "Remove from watchlist") : String(localized: "Add to watchlist")
        case .next:
            return following?.episodeLabel.map { String(localized: "Play next episode · \($0)", comment: "The placeholder is an episode label such as S1 · E2") } ?? String(localized: "Play next episode")
        case .shuffle:
            return String(localized: "Shuffle all episodes")
        case .trailer:
            return Trailers.title
        case .play, nil:
            return nil
        }
    }

    private func playLabel(for episode: BaseItem) -> String {
        let resume = episode.resumeTicks > 0
        if let label = episode.episodeLabel {
            return resume ? String(localized: "Resume \(label)") : String(localized: "Play \(label)")
        }
        return resume ? String(localized: "Resume") : String(localized: "Play")
    }
}

// MARK: - Episodes

/// A season's episodes, as the film page's shelves are: a fixed heading and
/// cards that say what they are, nothing that follows focus. Anything above
/// that changed with focus (the page's header, then the row's own title and
/// plot) redrew on every click, and on an older Apple TV the row flashed and
/// jumped as it went. Its focus is its own, so the page can hand it back.
private struct EpisodeRow: View {
    let episodes: [BaseItem]
    /// The page's count of reads: the cards redraw for new positions.
    var version = 0
    let seasonTitle: String
    let played: [String: Bool]
    let selection: Set<String>?
    @Binding var focusRequest: String?
    let menuActions: (BaseItem, Int) -> [ItemMenuAction]
    let choose: (BaseItem) -> Void

    @FocusState private var focus: String?

    var body: some View {
        Shelf(title: seasonTitle, eyebrow: String(localized: "Episodes")) {
            ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                EpisodeCard(episode: episode, focus: $focus,
                            played: played[episode.id] ?? (episode.userData?.played == true),
                            progress: episode.resumeTicks,
                            selected: selection.map { $0.contains(episode.id) },
                            menuActions: { menuActions(episode, index) }) {
                    choose(episode)
                }
            }
        }
        .onChange(of: focusRequest) { _, id in
            guard let id else { return }
            focus = id
            focusRequest = nil
        }
    }
}

// MARK: - Cast and crew

/// The page's lower shelves as views of their own: with inputs that haven't
/// changed, SwiftUI leaves them be when the page redraws.
private struct CastShelf: View {
    let people: [Person]
    @Environment(\.sectionNavigator) private var navigator

    /// Who the shelf shows: the cast, then who directed and wrote it.
    static func listed(_ people: [Person]) -> [Person] {
        let cast = people.filter { $0.type == "Actor" && $0.name != nil }
        let crew = people.filter { ["Director", "Writer"].contains($0.type ?? "") && $0.name != nil }
        return Array(cast.prefix(18) + crew.prefix(4))
    }

    var body: some View {
        let all = Self.listed(people)
        if !all.isEmpty {
            Shelf(title: String(localized: "Cast and Crew"), eyebrow: String(localized: "Who's in it"), accent: Theme.palette[3]) {
                ForEach(all) { person in
                    CastCard(person: person) { navigator.showPerson(person) }
                }
            }
        }
    }
}

private struct SimilarShelf: View {
    let items: [BaseItem]

    var body: some View {
        Shelf(title: String(localized: "More Like This"), eyebrow: String(localized: "Similar titles"), accent: Theme.palette[2]) {
            ForEach(items) { other in
                PosterNavCard(item: other, width: Theme.posterWidth)
            }
        }
    }
}

struct CastCard: View {
    /// A photograph's side.
    static let side: CGFloat = Theme.isPhone ? 112 : 160
    let person: Person
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                PersonPhoto(person: person, glyphSize: 44)
                    .frame(width: Self.side, height: Self.side)
                    .clipped()
            }
            .buttonStyle(.tvCard)
            .accessibilityLabel([person.name, person.role].compactMap { $0 }.joined(separator: ", "))
            .accessibilityHint("Shows what else they are in")

            VStack(alignment: .leading, spacing: 2) {
                Text(person.name ?? "")
                    .font(.app(15, .semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.app(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: Self.side, alignment: .leading)
        }
    }

    private var subtitle: String {
        if person.type == "Actor", let role = person.role, !role.isEmpty { return role }
        return person.type.map(ServerWords.personType) ?? ""
    }
}

/// A cast or crew member's photograph, or a silhouette for someone without one.
struct PersonPhoto: View {
    @Environment(\.appState) private var app
    let person: Person
    /// How wide a picture to ask the server for.
    var maxWidth = 300
    var glyphSize: CGFloat

    var body: some View {
        if let url = app?.client?.personImageURL(person, maxWidth: maxWidth) {
            RemoteImage(url: url)
        } else {
            ZStack {
                Theme.surface
                Image(systemName: "person.fill")
                    .font(.app(glyphSize))
                    .foregroundStyle(.white.opacity(0.2))
            }
        }
    }
}

/// A plot or a biography: a few lines of it, and a click for the rest. With
/// `full`, the short form is a different text (a biography's first
/// paragraph); without, it's the same text cut to `lines`.
struct ExpandableText: View {
    let text: String
    var full: String? = nil
    let lines: Int
    var maxWidth: CGFloat = .infinity
    /// Its own, so opening it redraws the text and not the page around it.
    @State private var expanded = false

    var body: some View {
        Button {
            withAnimation { expanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(expanded ? (full ?? text) : text)
                    .font(.app(19))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineSpacing(4)
                    .lineLimit(expanded ? nil : lines)
                    .multilineTextAlignment(.leading)
                // LESS goes where there's nothing more to take away.
                if full == nil || full != text || !expanded {
                    Text(expanded ? String(localized: "LESS", comment: "Collapses the plot summary")
                                  : String(localized: "MORE", comment: "Expands the plot summary"))
                        .font(.app(13, .bold))
                        .kerning(1)
                        .foregroundStyle(Theme.accent)
                }
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
        }
        .buttonStyle(OverviewButtonStyle())
    }
}

extension BaseItem {
    /// The same film in another library: same title, same year.
    var titleAndYear: String {
        "\(displayTitle.lowercased())|\(productionYear ?? 0)"
    }
}

extension Binding {
    /// Whether an optional has a value, for an alert or dialog shown while it
    /// does; dismissing it clears the value.
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}

/// The plot summary as a control. The system's plain style turned it into a
/// pale panel under white text, which could hardly be read; this lifts it on
/// a faint glass instead and keeps the words bright.
struct OverviewButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.white.opacity(focused ? 0.12 : 0))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(.white.opacity(focused ? 0.18 : 0), lineWidth: 1)
                    }
            }
            .padding(.horizontal, -16)
            .scaleEffect(focused ? 1.02 : (configuration.isPressed ? 0.99 : 1))
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

struct ScoreBadge: View {
    let label: String
    let value: String
    let colors: (Color, Color)

    var body: some View {
        HStack(spacing: 6) {
            Text(value).font(.app(16, .bold))
            Text(label).font(.app(14)).opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 7)
        .padding(.horizontal, 14)
        .background(Theme.gradient(colors, start: .topLeading, end: .bottomTrailing), in: Capsule())
    }
}

// MARK: - Episode card

struct EpisodeCard: View {
    @Environment(\.appState) private var app
    let episode: BaseItem
    var focus: FocusState<String?>.Binding
    var played: Bool
    /// Where it was left: the card redraws for a new position, which the
    /// episode alone (equal by its id) doesn't make.
    var progress: Int64 = 0
    /// Whether it's picked, while episodes are being picked.
    var selected: Bool? = nil
    /// Its own long-press menu rows, worked out as the menu opens.
    var menuActions: (() -> [ItemMenuAction])? = nil
    let action: () -> Void

    /// How long it runs and the day it first aired: "31m · 4 Sep 2025".
    private var details: String? {
        let parts = [
            episode.runtimeMinutes.map { String(localized: "\($0)m", comment: "Episode runtime in minutes, abbreviated") },
            episode.premiereDay.map { $0.formatted(date: .abbreviated, time: .omitted) },
        ].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: app?.client?.imageURL(for: episode, maxWidth: 800))
                        .frame(width: Theme.landscapeWidth, height: Theme.landscapeWidth * 9 / 16)
                        .clipped()
                    if let progress = episode.progressFraction {
                        WatchProgressBar(fraction: progress)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if selected == nil, played {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.app(38))
                            .foregroundStyle(Theme.accent)
                            .padding(10)
                    }
                }
                #if !os(tvOS)
                .overlay(alignment: .bottomTrailing) { DownloadBadge(id: episode.id) }
                #endif
                // Picking: a box on every card, ticked on the picked ones,
                // and the rest dimmed.
                .overlay {
                    if let selected {
                        ZStack(alignment: .topLeading) {
                            Color.black.opacity(selected ? 0 : 0.45)
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                .font(.app(38, .semibold))
                                .foregroundStyle(selected ? Theme.accent : .white.opacity(0.85))
                                .shadow(color: .black.opacity(0.5), radius: 4)
                                .padding(12)
                        }
                    }
                }
            }
            .buttonStyle(.tvCard)
            .accessibilityLabel(episode.spokenDescription)
            .accessibilityValue(selected == true ? String(localized: "Selected") : "")
            .accessibilityHint(selected != nil ? String(localized: "Selects or deselects")
                               : episode.resumeTicks > 0 ? String(localized: "Resumes playing") : String(localized: "Plays"))
            .focused(focus, equals: episode.id)
            .itemContextMenu(episode, moreActions: selected == nil ? menuActions : nil)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(episode.indexNumber.map { "\($0). " } ?? "")\(episode.displayTitle)")
                    .font(.app(17))
                    .lineLimit(1)
                if let details {
                    Text(details)
                        .font(.app(14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                // What it's about, under the card rather than above the row: a
                // text that followed focus redrew the row on every click (see
                // EpisodeRow). Two lines kept on every card, so the row stays
                // even whether a plot is long, short or missing.
                Text(episode.overview ?? "")
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary.opacity(0.85))
                    .lineLimit(2, reservesSpace: true)
                    .padding(.top, 4)
            }
            .frame(width: Theme.landscapeWidth, alignment: .leading)
        }
    }
}

private extension View {
    /// A row of buttons that can be wider than a phone held upright: moved
    /// along by a swipe rather than cut off at the edge.
    @ViewBuilder
    func scrollsSidewaysOnPhone() -> some View {
        #if !os(tvOS)
        ScrollView(.horizontal, showsIndicators: false) {
            self.padding(.vertical, 4)
        }
        #else
        self
        #endif
    }
}
