import SwiftUI

// MARK: - Remote image

struct RemoteImage: View {
    let url: URL?
    var contentMode: ContentMode = .fill
    /// Which part of an oversized image survives the crop.
    var alignment: Alignment = .center
    /// What stands in for a picture there isn't, or isn't yet: a film, a note.
    var symbol = "film"
    @State private var image: UIImage?

    init(url: URL?, contentMode: ContentMode = .fill, alignment: Alignment = .center, symbol: String = "film") {
        self.url = url
        self.contentMode = contentMode
        self.alignment = alignment
        self.symbol = symbol
        // Synchronous cache hit avoids a placeholder flash when cells recycle.
        _image = State(initialValue: ImagePipeline.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard let url else { image = nil; return }
            if let hit = ImagePipeline.cached(url) { image = hit; return }
            image = nil
            guard let loaded = await ImagePipeline.load(url), !Task.isCancelled else { return }
            // Cache hits above paint instantly; only network arrivals fade in.
            withAnimation(.easeOut(duration: 0.18)) { image = loaded }
        }
    }

    private var placeholder: some View {
        ZStack {
            Theme.surface
            // None for a banner, whose title sits over the middle of it.
            if !symbol.isEmpty {
                Image(systemName: symbol)
                    .font(.app(40))
                    .foregroundStyle(.white.opacity(0.15))
            }
        }
    }
}

// MARK: - Progress bar overlay

struct WatchProgressBar: View {
    @Environment(\.appTheme) private var theme
    let fraction: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(Theme.gradient(theme.colors.palette[0]))
                    .frame(width: max(8, geo.size.width * fraction))
            }
        }
        .frame(height: 6)
    }
}

// MARK: - Unwatched count badge (Plezy-style corner counter)

struct UnwatchedBadge: View {
    @Environment(\.appTheme) private var theme
    let count: Int

    var body: some View {
        Text("\(count)")
            .font(.app(23, .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, CGFloat(10).scaled)
            .padding(.vertical, CGFloat(5).scaled)
            .background(Theme.gradient(theme.colors.palette[0], start: .topLeading, end: .bottomTrailing),
                        in: Capsule())
            .padding(8)
    }
}

/// Seen all the way through: a film, or a show with nothing left.
struct WatchedBadge: View {
    @Environment(\.appTheme) private var theme

    var body: some View {
        Image(systemName: "checkmark")
            .font(.app(20, .heavy))
            .foregroundStyle(.white)
            .frame(width: CGFloat(40).scaled, height: CGFloat(40).scaled)
            .background(Theme.gradient(theme.colors.palette[0], start: .topLeading, end: .bottomTrailing),
                        in: Circle())
            .padding(8)
            .accessibilityLabel(String(localized: "Watched"))
    }
}

/// Hears focus move for the screen that keeps it, so the screen needn't read
/// the focus itself: one that does runs its whole body again on every step
/// along a row. Only this, an empty view, runs again.
struct FocusWatcher<Value: Hashable>: View {
    var focus: FocusState<Value>.Binding
    let moved: (_ old: Value, _ new: Value) -> Void

    var body: some View {
        Color.clear
            .onChange(of: focus.wrappedValue) { old, new in moved(old, new) }
    }
}

// MARK: - Poster card (2:3)

/// Poster artwork without its own Button, for use inside a NavigationLink.
struct PosterCardContent: View {
    @Environment(\.appState) private var app
    @Environment(\.borrowsGuideArt) private var borrowsGuideArt
    let item: BaseItem
    /// Fixed width for shelves; nil lets the poster fill its grid cell.
    var width: CGFloat? = nil

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.clear
                .aspectRatio(2 / 3, contentMode: .fit)
                .overlay {
                    let own = app?.client?.imageURL(for: item, maxWidth: 440)
                    if borrowsGuideArt == true, item.lacksPoster {
                        RecordingArt(item: item, own: own, known: app?.knownRecordingCover(for: item)?.url)
                    } else {
                        RemoteImage(url: own)
                    }
                }
                .clipped()
                // Touches inside the frame only: a filled picture spills past it.
                .contentShape(.interaction, Rectangle())
            if let unplayed = item.userData?.unplayedItemCount, unplayed > 0, item.isSeries {
                UnwatchedBadge(count: unplayed)
            } else if item.userData?.played == true {
                WatchedBadge()
            }
        }
        // Still being recorded, as the guide marks what is.
        .overlay(alignment: .topLeading) {
            if item.isBeingRecorded {
                LiveRecordingDot(size: 11, says: String(localized: "Recording", comment: "Live TV: the server is recording this programme now"))
                    .padding(7)
                    .background(.black.opacity(0.55), in: Circle())
                    .padding(10)
            }
        }
        // Part-way through a film: how far, the way the episode cards show it.
        .overlay(alignment: .bottom) {
            if !item.isSeries, let progress = item.progressFraction {
                WatchProgressBar(fraction: progress)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
            }
        }
        .keepsCardCorners()
        .frame(width: width)
    }
}

/// A card being chosen among others, not opened: a grid picking out
/// recordings to delete. Whether it's one of the chosen, and what a press
/// on it does; nil for a card that can't be chosen (a show, a folder).
struct CardPick {
    let picked: Bool
    let toggle: (() -> Void)?
}

/// The mark of a card that's been chosen, or the ring where one would go.
struct PickMark: View {
    let picked: Bool

    var body: some View {
        Image(systemName: picked ? "checkmark.circle.fill" : "circle")
            .font(.system(size: CGFloat(30).scaled, weight: .semibold))
            .symbolRenderingMode(.palette)
            .foregroundStyle(.white, picked ? Theme.primary.0 : Color.black.opacity(0.35))
            .shadow(color: .black.opacity(0.5), radius: 4, y: 1)
            .padding(10)
    }
}

/// Poster with its title beneath, navigating to the item's detail page.
/// The one card used by every shelf and grid of navigable posters.
struct PosterNavCard: View {
    @Environment(\.sectionNavigator) private var navigator
    let item: BaseItem
    /// Fixed width for shelves; nil lets the card fill its grid cell.
    var width: CGFloat? = nil
    /// For a grid that tracks and moves focus by item id.
    var focus: FocusState<String?>.Binding? = nil
    /// The card's value in `focus`; the item's id unless the row says otherwise.
    var focusID: String? = nil
    /// Set while the grid is choosing among its cards: a press chooses this
    /// one or lets it go, and nothing opens.
    var pick: CardPick? = nil
    /// Rows of the screen's own for the card's long-press menu.
    var menuActions: (() -> [ItemMenuAction])? = nil
    /// A second line under the name, where the grid has something to say
    /// of each title (when a recording was made).
    var note: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let pick {
                Button { pick.toggle?() } label: {
                    PosterCardContent(item: item, width: width)
                        .overlay(alignment: .topLeading) { if pick.toggle != nil { PickMark(picked: pick.picked) } }
                }
                .buttonStyle(.tvCard)
                .focused(by: focus, id: focusID ?? item.id)
                .disabled(pick.toggle == nil)
                .opacity(pick.toggle == nil ? 0.35 : 1)
                .accessibilityLabel(item.spokenDescription)
                .accessibilityAddTraits(pick.picked ? .isSelected : [])
            } else {
                NavigationLink(value: item) {
                    PosterCardContent(item: item, width: width)
                }
                .buttonStyle(.tvCard)
                .focused(by: focus, id: focusID ?? item.id)
                .itemContextMenu(item, offersPlay: true, showDetails: goToShow, moreActions: menuActions)
                .accessibilityLabel(item.spokenDescription)
                .accessibilityHint("Opens details")
            }
            VStack(alignment: .leading, spacing: 2) {
                // A recording the server filed under a show: the show's name,
                // not its own ("… S2026E288"). Recordings are the cards a note goes with.
                Text(note != nil && item.isEpisode ? item.seriesName ?? item.displayTitle : item.displayTitle)
                    .font(.app(16))
                    .lineLimit(1)
                if let note {
                    Text(note)
                        .font(.app(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }

    /// An episode's poster opens the episode: its show's page, from the
    /// long-press menu. Only where the section can open a page by its id.
    private var goToShow: (() -> Void)? {
        guard item.isEpisode, let show = item.seriesId, !navigator.section.isEmpty else { return nil }
        let navigator = navigator
        return { navigator.showItem(show) }
    }
}

extension View {
    /// Takes part in a row's own focus keeping, where the row keeps any.
    @ViewBuilder
    func focused(by focus: FocusState<String?>.Binding?, id: String) -> some View {
        if let focus { focused(focus, equals: id) } else { self }
    }
}

extension View {
    /// The card button style rounds a card's corners only while it can take
    /// focus. A card held out of focus (the Apple TV's Home, while you're in
    /// the menu) keeps them with this.
    func keepsCardCorners() -> some View {
        modifier(KeepsCardCorners())
    }
}

private struct KeepsCardCorners: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        // One clip either way, so the card isn't rebuilt as it's held and let go.
        content.clipShape(RoundedRectangle(cornerRadius: isEnabled ? 0 : 12, style: .continuous))
    }
}

// MARK: - Landscape card (16:9, used for Continue Watching / Next Up)

struct LandscapeCard: View {
    @Environment(\.appState) private var app
    let item: BaseItem
    /// Opens the item's page (its show's, for an episode) from the long-press menu.
    var showDetails: (() -> Void)? = nil
    /// On a Next Up shelf: the long-press menu can take it off.
    var removesFromNextUp = false
    /// A click opens the item's page rather than playing it, so the
    /// long-press menu offers Play in place of Details.
    var opensPage = false
    /// For a row that tracks and moves focus itself (the Apple TV's Home).
    var focus: FocusState<String?>.Binding? = nil
    /// The card's value in `focus`; the item's id unless the row says otherwise.
    var focusID: String? = nil
    /// Wider than usual where a grid shares out its row.
    var width: CGFloat = Theme.landscapeWidth
    let action: () -> Void
    /// A recording's picture where it has none of its own (see `recordingCover`).
    @State private var cover: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    RemoteImage(url: landscapeURL ?? cover)
                        .frame(width: width, height: width * 9 / 16)
                        .clipped()
                        .contentShape(.interaction, Rectangle())
                    if let progress = item.progressFraction {
                        WatchProgressBar(fraction: progress)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                }
                .keepsCardCorners()
            }
            .buttonStyle(.tvCard)
            .focused(by: focus, id: focusID ?? item.id)
            .itemContextMenu(item, offersPlay: opensPage, showDetails: opensPage ? nil : showDetails,
                             removesFromNextUp: removesFromNextUp)
            .accessibilityLabel(item.spokenDescription)
            .accessibilityHint(opensPage ? String(localized: "Opens details")
                               : item.resumeTicks > 0 ? String(localized: "Resumes playing") : String(localized: "Plays"))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle)
                    .font(.app(17))
                    .lineLimit(1)
                if let label = subtitle {
                    Text(label)
                        .font(.app(14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            .frame(width: width, alignment: .leading)
        }
        // Only for a card with no picture at all: a recording in Continue
        // Watching, which the server gives none. Its show's backdrop, or the
        // guide's picture of it, as its page has.
        .task(id: item.id) {
            guard landscapeURL == nil, let app else { return }
            cover = app.knownRecordingCover(for: item)?.url
            if cover == nil { cover = await app.recordingCover(for: item)?.url }
        }
    }

    private var landscapeURL: URL? {
        if item.isEpisode, item.imageTags?["Primary"] != nil {
            return app?.client?.imageURL(for: item, type: "Primary", maxWidth: 800)
        }
        return app?.client?.imageURL(for: item, type: "Backdrop", maxWidth: 800)
            ?? app?.client?.imageURL(for: item, type: "Primary", maxWidth: 800)
    }

    private var subtitle: String? {
        // Still to air: when, and which.
        if AirDay.isComing(item) { return AirDay.caption(item) }
        if let ep = item.episodeLabel {
            return "\(ep) · \(item.displayTitle)"
        }
        // A recording: when it went out, not the show's first year.
        if let aired = Recorded.aired(item) { return aired }
        if let year = item.productionYear { return String(year) }
        return nil
    }
}

// MARK: - Long-press item menu

extension View {
    /// The long-press menu every item card shares. The card only asks for it;
    /// the menu and anything it starts playing are presented once, from
    /// `itemMenuHost()`, rather than carried by every card on a grid.
    /// - Parameters:
    ///   - offersPlay: add Play / Resume, for cards whose click opens details instead.
    ///   - showDetails: add a link to the item's page, for cards whose click plays.
    ///   - removesFromNextUp: add Remove from Next Up, for cards on that shelf.
    ///   - extraActions: rows of the screen's own, after the watched row.
    func itemContextMenu(_ item: BaseItem, offersPlay: Bool = false,
                         showDetails: (() -> Void)? = nil, removesFromNextUp: Bool = false,
                         extraActions: [ItemMenuAction] = [],
                         moreActions: (() -> [ItemMenuAction])? = nil) -> some View {
        modifier(ItemContextMenu(request: ItemMenuRequest(item: item, offersPlay: offersPlay,
                                                          showDetails: showDetails,
                                                          removesFromNextUp: removesFromNextUp,
                                                          extraActions: extraActions),
                                 more: moreActions))
    }

    /// A long-press menu of the card's own rows and no others, under a
    /// heading of its own (see `ItemMenuRequest.heading`). Both are worked
    /// out as the menu is asked for; with no rows, none opens.
    func ownContextMenu(_ item: BaseItem,
                        asked: @escaping () -> (heading: ItemMenuRequest.Heading, rows: [ItemMenuAction])?) -> some View {
        modifier(OwnContextMenu(item: item, asked: asked))
    }

    /// The long-press menu of a playlist's or a collection's own card, and
    /// no menu on a library's.
    @ViewBuilder
    func containerMenu(_ item: BaseItem) -> some View {
        if item.isContainer { itemContextMenu(item) } else { self }
    }

    /// Where long-press menus open from, and the player they start. Once, at
    /// the top of the screens that have cards.
    func itemMenuHost() -> some View {
        modifier(ItemMenuHost())
    }
}

/// A card's long-press menu, as asked for.
struct ItemMenuRequest: Identifiable {
    let item: BaseItem
    let offersPlay: Bool
    let showDetails: (() -> Void)?
    let removesFromNextUp: Bool
    var extraActions: [ItemMenuAction] = []
    /// The card is among the server's recordings, which this account may
    /// delete (see `recordingsDeletable`).
    var deletable = false
    /// What heads the menu, where the card isn't a film or a show with a
    /// title and a poster to head it: a television channel, headed by what's
    /// on it. Such a menu holds the card's own rows and no others: there's
    /// nothing of a channel to mark watched.
    var heading: Heading?

    struct Heading {
        let eyebrow: String
        let title: String
        let detail: String?
        let picture: URL?
        /// The picture is a mark, to be shown whole (a station's logo), not
        /// a picture to fill its frame.
        var fits = false
    }

    var id: String { item.id }
}

/// Takes the cards' requests to the host. A reference that never changes, so
/// the cards reading it from the environment never redraw because of it.
@MainActor
final class ItemMenuPresenter: ObservableObject {
    @Published var request: ItemMenuRequest?

    func open(_ request: ItemMenuRequest) {
        // The panel animates itself; skip the cover's slide-up.
        withTransaction(Transaction(animation: nil).disablingAnimations()) { self.request = request }
    }
}

private struct ItemMenuPresenterKey: EnvironmentKey {
    static let defaultValue: ItemMenuPresenter? = nil
}

private extension EnvironmentValues {
    var itemMenu: ItemMenuPresenter? {
        get { self[ItemMenuPresenterKey.self] }
        set { self[ItemMenuPresenterKey.self] = newValue }
    }
}

private struct RecordingsDeletableKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Whether the cards here are the server's recordings, in a library
    /// this account may delete from: their long-press menu then offers to
    /// delete one. Set by the screen that lists them; a card anywhere else
    /// has no Delete, whatever the account may do.
    var recordingsDeletable: Bool {
        get { self[RecordingsDeletableKey.self] }
        set { self[RecordingsDeletableKey.self] = newValue }
    }
}

struct ItemMenuAction: Identifiable {
    let title: String
    let icon: String
    var destructive = false
    let run: () -> Void

    var id: String { title }
}

private struct ItemContextMenu: ViewModifier {
    @Environment(\.itemMenu) private var menu
    @Environment(\.recordingsDeletable) private var deletable
    let request: ItemMenuRequest
    /// Rows worked out as the menu is asked for, not when the card was
    /// drawn: they may depend on what has arrived since.
    var more: (() -> [ItemMenuAction])? = nil

    func body(content: Content) -> some View {
        content.highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in open() })
            #if os(macOS)
            // A Mac's way to it: a right click.
            .onSecondaryClick(open)
            #endif
    }

    private func open() {
        var asked = request
        asked.deletable = deletable
        if let more { asked.extraActions += more() }
        menu?.open(asked)
    }
}

private struct OwnContextMenu: ViewModifier {
    @Environment(\.itemMenu) private var menu
    let item: BaseItem
    let asked: () -> (heading: ItemMenuRequest.Heading, rows: [ItemMenuAction])?

    func body(content: Content) -> some View {
        content.highPriorityGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in open() })
            #if os(macOS)
            .onSecondaryClick(open)
            #endif
    }

    private func open() {
        guard let asked = asked(), !asked.rows.isEmpty else { return }
        menu?.open(ItemMenuRequest(item: item, offersPlay: false, showDetails: nil, removesFromNextUp: false,
                                   extraActions: asked.rows, heading: asked.heading))
    }
}

private struct ItemMenuHost: ViewModifier {
    @Environment(\.appState) private var app
    @StateObject private var menu = ItemMenuPresenter()
    /// Runs once the menu is gone, so a player cover can present in its place.
    @State private var pending: ItemMenuAction?
    @State private var playing: BaseItem?
    @State private var playingFromBeginning = false
    /// A recording asked to be deleted, until that's been confirmed or let be.
    @State private var deleting: BaseItem?
    /// What went wrong deleting it, while that's being said.
    @State private var deleteProblem: String?
    /// Songs asked to go into a playlist, while one is chosen.
    @State private var addingToPlaylist: PlaylistAddition?
    #if !os(tvOS)
    /// Why a download from the menu didn't start.
    @State private var downloadProblem: String?
    #endif
    /// Changes already made from a menu, so a menu opened again before the
    /// screen has reloaded reads right. Each holds the item's state as it was
    /// seen, and stops applying once the item arrives changed.
    @State private var overrides: [String: Override] = [:]

    private struct Override {
        let seen: UserData?
        var played: Bool?
        var favorite: Bool?
        var watchlisted: Bool?
        var resumeCleared = false
    }

    func body(content: Content) -> some View {
        content
            .environment(\.itemMenu, menu)
            .fullScreenCover(item: $menu.request, onDismiss: {
                // Details/Go to Show push a page whose content takes a moment to
                // appear; without this the menu claims the focus in between.
                if pending != nil { app?.holdMenuFocus() }
                pending?.run()
                pending = nil
            }) { request in
                ItemMenuPanel(item: request.item, heading: request.heading, actions: actions(for: request)) { action in
                    pending = action
                    withTransaction(Transaction(animation: nil).disablingAnimations()) { menu.request = nil }
                }
                .presentationBackground(.clear)
            }
            .playerCover(item: $playing) { PlayerView(item: $0, fromBeginning: playingFromBeginning) }
            // From a view of its own: two covers on the one view aren't to be relied on.
            .background {
                Color.clear.fullScreenCover(item: $addingToPlaylist) { addition in
                    PlaylistPicker(addition: addition)
                        .presentationBackground(.clear)
                }
            }
            .onChange(of: playing) { _, newValue in
                // The player itself announces the change as it closes.
                if newValue == nil { playingFromBeginning = false }
            }
            // Asked twice: it's the file that goes, and there's no having it back.
            .confirmationDialog(deleting?.displayTitle ?? "", isPresented: $deleting.isPresent(), titleVisibility: .visible,
                                presenting: deleting) { item in
                switch item.type {
                case "Playlist":
                    Button(String(localized: "Delete Playlist", comment: "Deletes a playlist of songs from the server"),
                           role: .destructive) { delete(item) }
                case "BoxSet":
                    Button(String(localized: "Delete Collection", comment: "Deletes a collection from the server; what's in it stays"),
                           role: .destructive) { delete(item) }
                default:
                    Button(String(localized: "Delete Recording", comment: "Deletes a recording from the server: its file is removed"),
                           role: .destructive) { delete(item) }
                }
                Button("Cancel", role: .cancel) {}
            } message: { item in
                switch item.type {
                case "Playlist":
                    Text("The playlist is deleted from your server. What's in it stays in your library.",
                         comment: "Asked before a playlist of films or episodes is deleted")
                case "BoxSet":
                    Text("The collection is deleted from your server. What's in it stays in your library.",
                         comment: "Asked before a collection is deleted")
                default:
                    Text("The recording is deleted from your server and can't be brought back.",
                         comment: "Asked before a recording is deleted")
                }
            }
            .alert(deleteProblem ?? "", isPresented: $deleteProblem.isPresent()) {}
            #if !os(tvOS)
            .alert(downloadProblem ?? "", isPresented: $downloadProblem.isPresent()) {}
            #endif
    }

    private func delete(_ item: BaseItem) {
        guard let client = app?.client else { return }
        Task {
            do {
                try await client.deleteItem(item.id)
                app?.holdMenuFocus()
                app?.deleted([item.id])
                if item.isContainer { app?.collectionsChanged() }
            } catch {
                deleteProblem = switch item.type {
                case "Playlist": String(localized: "Couldn't delete the playlist.", comment: "The server refused to delete a playlist of songs, or didn't answer")
                case "BoxSet": String(localized: "Couldn't delete the collection.", comment: "The server refused to delete a collection, or didn't answer")
                default: String(localized: "Couldn't delete the recording.", comment: "The server refused or didn't answer when asked to delete a recording")
                }
            }
        }
    }

    private func actions(for request: ItemMenuRequest) -> [ItemMenuAction] {
        // A card with a heading of its own has only its own rows.
        if request.heading != nil { return request.extraActions }
        if request.item.isMusic { return musicActions(for: request) }
        let item = request.item
        let override = overrides[item.id].flatMap { $0.seen == item.userData ? $0 : nil }
        let isPlayed = override?.played ?? item.userData?.played ?? false
        let isFavorite = override?.favorite ?? item.userData?.isFavorite ?? false
        // Marked for the watchlist, and on it for as long as it's unwatched.
        let marked = override?.watchlisted ?? (item.userData?.likes == true)
        let inProgress = item.resumeTicks > 0 && override?.resumeCleared != true && !isPlayed

        var actions: [ItemMenuAction] = []
        if request.offersPlay, !item.isSeries {
            actions.append(.init(title: inProgress ? String(localized: "Resume") : String(localized: "Play"), icon: "play.fill") { playing = item })
        }
        // Offered even where a click resumes, so Continue Watching can start over.
        if inProgress, !item.isSeries {
            actions.append(.init(title: String(localized: "Play from Beginning"), icon: "arrow.counterclockwise") {
                playingFromBeginning = true
                playing = item
            })
        }
        if let showDetails = request.showDetails {
            actions.append(.init(title: item.isEpisode ? String(localized: "Go to Show") : String(localized: "Details"), icon: "info.circle",
                                 run: showDetails))
        }
        #if !os(tvOS)
        let download = downloadAction(for: item)
        if let download, !download.destructive { actions.append(download) }
        #endif
        let played = !isPlayed
        actions.append(.init(title: played ? String(localized: "Mark as Watched") : String(localized: "Mark as Unwatched"),
                             icon: played ? "eye" : "eye.slash") {
            send(item, {
                $0.played = played
                if played, marked { $0.watchlisted = false }
            }) {
                try await $0.setPlayed(item.id, played)
                // Watched is off the watchlist, and for good: unwatching it
                // later doesn't put it back.
                if played, marked { try? await $0.setWatchlisted(item.id, false) }
            }
        })
        // Into a playlist of films and episodes (a show or a season, all its
        // episodes), or a collection, where this account may make them.
        if item.isOneVideo || item.isSeries || item.type == "Season", !item.isUpcoming {
            actions.append(.init(title: String(localized: "Add to Playlist…", comment: "Puts songs in a playlist, chosen next"),
                                 icon: "text.badge.plus") {
                addingToPlaylist = .video(item, into: .videoPlaylist)
            })
        }
        if item.isMovie || item.isSeries, app?.managesCollections == true {
            actions.append(.init(title: String(localized: "Add to Collection…", comment: "Puts a film or a show in a collection, chosen next"),
                                 icon: "rectangle.stack.badge.plus") {
                addingToPlaylist = .video(item, into: .collection)
            })
        }
        // The screen's own rows; any that take something away go last,
        // with the others that do.
        actions += request.extraActions.filter { !$0.destructive }
        let favorite = !isFavorite
        actions.append(.init(title: favorite ? String(localized: "Add to Favourites") : String(localized: "Remove from Favourites"),
                             icon: favorite ? "star" : "star.slash") {
            send(item, { $0.favorite = favorite }, favorites: true) { try await $0.setFavorite(item.id, favorite) }
        })
        // A film to be watched: so not one that has been, which watching
        // took off the list.
        if item.isMovie, !isPlayed {
            let listed = !marked
            actions.append(.init(title: listed ? String(localized: "Add to Watchlist") : String(localized: "Remove from Watchlist"),
                                 icon: listed ? "bookmark" : "bookmark.slash") {
                send(item, { $0.watchlisted = listed }, watchlist: true) { try await $0.setWatchlisted(item.id, listed) }
            })
        }
        if request.removesFromNextUp {
            // Nothing to send: it's kept on this Apple TV (see AppState).
            actions.append(.init(title: String(localized: "Remove from Next Up"), icon: "minus.circle",
                                 destructive: true) { app?.removeFromNextUp(item.id) })
        }
        if inProgress {
            actions.append(.init(title: String(localized: "Remove from Continue Watching"), icon: "minus.circle",
                                 destructive: true) {
                send(item, { $0.resumeCleared = true }) { try await $0.clearResumePosition(item.id) }
            })
        }
        // A recording, one showing of something: not a show with every
        // episode of it under it, nor a folder, which would be far more
        // gone than a long press should be good for.
        actions += request.extraActions.filter(\.destructive)
        #if !os(tvOS)
        if let download, download.destructive { actions.append(download) }
        #endif
        if request.deletable, item.isOneVideo {
            actions.append(.init(title: String(localized: "Delete Recording", comment: "Deletes a recording from the server: its file is removed"),
                                 icon: "trash", destructive: true) { deleting = item })
        }
        // A playlist (its owner's to delete: the server says no to anyone
        // else) or a collection, itself: what's in it stays.
        if item.type == "Playlist" {
            actions.append(.init(title: String(localized: "Delete Playlist", comment: "Deletes a playlist of songs from the server"),
                                 icon: "trash", destructive: true) { deleting = item })
        } else if item.type == "BoxSet", app?.managesCollections == true {
            actions.append(.init(title: String(localized: "Delete Collection", comment: "Deletes a collection from the server; what's in it stays"),
                                 icon: "trash", destructive: true) { deleting = item })
        }
        return actions
    }

    /// A song's, an album's, a playlist's or an artist's: to play it, or
    /// after the song playing, or at the end of the queue; songs like it;
    /// where the card's screen can take it (its album, its artist); a favourite.
    private func musicActions(for request: ItemMenuRequest) -> [ItemMenuAction] {
        let item = request.item
        guard let client = app?.client else { return request.extraActions }
        let music = MusicPlayer.shared
        let songs = MusicMenu.songs(of: item, client: client)
        let source = item.isSong ? item.album : item.displayTitle
        var actions: [ItemMenuAction] = []
        if request.offersPlay {
            actions.append(.init(title: String(localized: "Play"), icon: "play.fill") {
                music.play(source: source, client: client, songs: songs)
            })
            if !item.isSong {
                actions.append(.init(title: String(localized: "Shuffle"), icon: "shuffle") {
                    music.play(source: source, shuffled: true, client: client, songs: songs)
                })
            }
        }
        actions.append(.init(title: String(localized: "Play Next", comment: "Music: plays it straight after the song playing"),
                             icon: "text.line.first.and.arrowtriangle.forward") {
            Task { if let found = try? await songs() { music.playNext(found, client: client) } }
        })
        actions.append(.init(title: String(localized: "Add to Queue", comment: "Music: plays it after everything already queued"),
                             icon: "text.append") {
            Task { if let found = try? await songs() { music.addToQueue(found, client: client) } }
        })
        if item.type != "Playlist" {
            actions.append(.init(title: String(localized: "Instant Mix", comment: "Plays songs like this one, chosen by the server"),
                                 icon: "dot.radiowaves.left.and.right") {
                music.play(source: String(localized: "Instant Mix"), client: client) {
                    try await client.instantMix(from: item.id, limit: 200)
                }
            })
        }
        // Not an artist's: a thousand songs at a press is more than a
        // playlist wants.
        if !item.isArtist {
            actions.append(.init(title: String(localized: "Add to Playlist…", comment: "Puts songs in a playlist, chosen next"),
                                 icon: "text.badge.plus") {
                addingToPlaylist = PlaylistAddition(item: item, items: songs)
            })
        }
        actions += request.extraActions.filter { !$0.destructive }
        // Kept by the stars that show it (a song's in a list, Now Playing's).
        let favorites = MusicFavorites.shared
        let favorite = !favorites.isFavorite(item)
        actions.append(.init(title: favorite ? String(localized: "Add to Favourites") : String(localized: "Remove from Favourites"),
                             icon: favorite ? "star" : "star.slash") {
            favorites.toggle(item, app: app)
        })
        actions += request.extraActions.filter(\.destructive)
        return actions
    }

    #if !os(tvOS)
    /// Download it to watch without the server, or stop or remove the
    /// download: one film, episode or finished recording (one still being
    /// made would come down cut short). Named for how things stand as the
    /// menu opens; what it does is decided when it's chosen, so a menu left
    /// open while a download finished can't throw it away.
    private func downloadAction(for item: BaseItem) -> ItemMenuAction? {
        guard item.isOneVideo || item.isSong, !item.isBeingRecorded, let client = app?.client as? MediaBrowserClient else { return nil }
        let downloads = Downloads.shared
        switch downloads.record(item.id)?.state {
        case .downloading:
            return .init(title: String(localized: "Cancel Download"), icon: "xmark.circle") {
                Task { await downloads.cancel(item.id) }
            }
        case .done:
            return .init(title: String(localized: "Remove Download"), icon: "trash", destructive: true) {
                downloads.removeFinished(item.id)
            }
        case .failed, nil:
            return .init(title: String(localized: "Download"), icon: "arrow.down.circle") {
                Task { downloadProblem = await downloads.download(item, client: client) }
            }
        }
    }
    #endif

    /// Applies a change to the menu straight away and sends it; takes it back
    /// if the server refuses.
    private func send(_ item: BaseItem, _ change: (inout Override) -> Void, favorites: Bool = false, watchlist: Bool = false,
                      _ request: @escaping (any MediaServer) async throws -> Void) {
        let previous = overrides[item.id]
        var updated = previous.flatMap { $0.seen == item.userData ? $0 : nil } ?? Override(seen: item.userData)
        change(&updated)
        overrides[item.id] = updated
        guard let client = app?.client else { overrides[item.id] = previous; return }
        Task {
            do {
                try await request(client)
                app?.userDataChanged(favorites: favorites, watchlist: watchlist, audiobooks: item.isAudiobook)
            } catch {
                overrides[item.id] = previous
            }
        }
    }
}

private extension Transaction {
    func disablingAnimations() -> Transaction {
        var copy = self
        copy.disablesAnimations = true
        return copy
    }
}

/// The long-press menu itself: the open sidebar's glass panel, headed by the
/// item the way the sidebar is headed by the wordmark.
private struct ItemMenuPanel: View {
    @Environment(\.appState) private var app
    let item: BaseItem
    var heading: ItemMenuRequest.Heading? = nil
    let actions: [ItemMenuAction]
    /// Called with the chosen row, or nil when backing out.
    let choose: (ItemMenuAction?) -> Void

    @State private var shown = false

    var body: some View {
        ZStack {
            Color.black.opacity(shown ? 0.55 : 0)
                .ignoresSafeArea()
                #if !os(tvOS)
                // A tap beside the menu puts it away.
                .contentShape(Rectangle())
                .onTapGesture { close(with: nil) }
                #endif

            VStack(alignment: .leading, spacing: 6) {
                header
                    .padding(.horizontal, 6)
                    .padding(.bottom, 22)
                ForEach(actions) { action in
                    Button { close(with: action) } label: {
                        HStack(spacing: 14) {
                            Image(systemName: action.icon)
                                .font(.app(18, .semibold))
                                .frame(width: CGFloat(24).scaled)
                            Text(action.title)
                                .lineLimit(1)
                        }
                    }
                    .buttonStyle(MenuRowStyle(destructive: action.destructive))
                    .focusEffectDisabled()   // the white row fill is the focus indicator
                }
            }
            .padding(.horizontal, CGFloat(22).scaled)
            .padding(.vertical, CGFloat(30).scaled)
            .frame(width: CGFloat(560).scaled)
            .background {
                GlassPanel()
                    .shadow(color: .black.opacity(0.5), radius: 40, y: 16)
            }
            .scaleEffect(shown ? 1 : 0.94)
            .opacity(shown ? 1 : 0)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.2)) { shown = true }
        }
        .tvExitCommand { close(with: nil) }
    }

    private var header: some View {
        HStack(spacing: 18) {
            picture
                .shadow(color: Theme.primary.0.opacity(0.45), radius: 12, y: 4)
            VStack(alignment: .leading, spacing: 4) {
                Text((heading?.eyebrow ?? eyebrow).uppercased())
                    .font(.app(12, .heavy))
                    .kerning(1.6)
                    .foregroundStyle(Theme.primary.1)
                    .lineLimit(1)
                Text(heading?.title ?? item.displayTitle)
                    .font(.app(24, .bold))
                    .lineLimit(2)
                if let detail = heading == nil ? detail : heading?.detail {
                    Text(detail)
                        .font(.app(15))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
    }

    @ViewBuilder
    private var picture: some View {
        if let heading {
            // A television picture's shape; a station's mark stands whole
            // on the theme's colour, as it does on its card.
            ZStack {
                Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing).opacity(0.4)
                if heading.fits {
                    RemoteImage(url: heading.picture, contentMode: .fit)
                        .padding(14)
                } else {
                    RemoteImage(url: heading.picture)
                }
            }
            .frame(width: 144, height: 81)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        } else if item.isMusic {
            MusicArt(item: item, maxWidth: 300)
                .frame(width: 96, height: 96)
                .clipShape(item.isArtist ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: 10)))
        } else {
            RemoteImage(url: app?.client?.imageURL(for: item, maxWidth: 300))
                .frame(width: item.isEpisode ? 144 : 72, height: item.isEpisode ? 81 : 108)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) {
                    if let progress = item.progressFraction {
                        WatchProgressBar(fraction: progress)
                            .padding(.horizontal, 6)
                            .padding(.bottom, 5)
                    }
                }
        }
    }

    private var eyebrow: String {
        if item.isSong { return String(localized: "Song", comment: "Kind of item, shown in capitals above its title") }
        if item.isAlbum { return String(localized: "Album", comment: "Kind of item, shown in capitals above its title") }
        if item.isArtist { return String(localized: "Artist", comment: "Kind of item, shown in capitals above its title") }
        if item.type == "Playlist" { return String(localized: "Playlist", comment: "Kind of item, shown in capitals above its title") }
        if item.type == "BoxSet" { return String(localized: "Collection", comment: "Kind of item, shown in capitals above its title") }
        if item.isEpisode { return item.seriesName ?? String(localized: "Episode", comment: "Kind of item, shown in capitals above its title") }
        return item.isSeries ? String(localized: "Series", comment: "Kind of item, shown in capitals above its title") : String(localized: "Movie", comment: "Kind of item, shown in capitals above its title")
    }

    private var detail: String? {
        if item.isSong { return [item.byLine, item.album].compactMap { $0 }.joined(separator: " · ") }
        if item.isAlbum { return [item.byLine, item.productionYear.map(String.init)].compactMap { $0 }.joined(separator: " · ") }
        if item.isMusic { return nil }
        if let label = item.episodeLabel { return label }
        var parts: [String] = []
        if let aired = Recorded.aired(item) {
            parts.append(aired)
        } else if let year = item.productionYear {
            parts.append(String(year))
        }
        if let minutes = item.runtimeMinutes, !item.isSeries {
            parts.append(Self.runtime(minutes))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1h 42m", or "48m" under an hour.
    static func runtime(_ minutes: Int) -> String {
        minutes >= 60 ? String(localized: "\(minutes / 60)h \(minutes % 60)m", comment: "Running time in hours and minutes, abbreviated")
                      : String(localized: "\(minutes)m", comment: "Running time in minutes, abbreviated")
    }

    /// Fades the panel out, then hands the choice back (which closes the cover).
    private func close(with action: ItemMenuAction?) {
        withAnimation(.easeIn(duration: 0.14)) { shown = false }
        Task {
            try? await Task.sleep(for: .milliseconds(140))
            choose(action)
        }
    }
}

/// A menu row lit like the sidebar's: white with a black label when focused.
struct MenuRowStyle: ButtonStyle {
    var destructive = false
    @Environment(\.isFocused) private var focused

    // Computed, not stored: a `static let` is initialised once for the life of
    // the process and would hold the first scheme's colour for ever.
    private static var destructiveTint: Color { Theme.palette[1].0 }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.app(19, .semibold))
            .foregroundStyle(destructive ? Self.destructiveTint : (focused ? .black : .white.opacity(0.8)))
            .padding(.vertical, CGFloat(13).scaled)
            .padding(.horizontal, CGFloat(16).scaled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(focused ? Color.white : .clear))
            .pointerWash(cornerRadius: 14)
            .shadow(color: focused ? .black.opacity(0.35) : .clear, radius: 14, y: 5)
            .scaleEffect(focused ? 1.04 : (configuration.isPressed ? 0.96 : 1))
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// The dimmed screen and glass panel these all share. On iPad a tap on the
/// dimmed screen closes it, as the remote's back does on the Apple TV.
struct PanelBackdrop<Content: View>: View {
    /// What a tap outside the panel does; nil closes the presentation.
    var onTapOutside: (() -> Void)? = nil
    @ViewBuilder let content: Content

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.opacity(0.55).ignoresSafeArea()
                #if !os(tvOS)
                .contentShape(Rectangle())
                .onTapGesture { if let onTapOutside { onTapOutside() } else { dismiss() } }
                #endif
            content
                .padding(CGFloat(36).scaled)
                .background {
                    GlassPanel().shadow(color: .black.opacity(0.5), radius: 40, y: 16)
                }
                // Off the edges of a phone's screen, which a panel's width can reach.
                .padding(.horizontal, Theme.isPhone ? 12 : 0)
        }
        .tvExitCommand { dismiss() }
    }
}

// MARK: - Glass panel

/// Frosted panel with a faint primary tint: the open sidebar and the item menu.
struct GlassPanel: View {
    @Environment(\.appTheme) private var theme
    var cornerRadius: CGFloat = 30

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        shape
            .fill(.ultraThinMaterial)
            .overlay(
                shape.fill(LinearGradient(colors: [theme.colors.palette[0].0.opacity(0.22),
                                                   theme.colors.palette[0].1.opacity(0.08)],
                                          startPoint: .top, endPoint: .bottom))
            )
            .overlay(shape.stroke(.white.opacity(0.10), lineWidth: 1))
    }
}

// MARK: - Horizontal shelf

struct Shelf<Content: View>: View {
    @Environment(\.appTheme) private var theme
    /// Beside an iPhone Duo's camera strip, the row stops at the page's edge
    /// rather than running on under the strip and its tab bar.
    @Environment(\.barEdge) private var barEdge
    let title: String
    /// Small colored label above the title ("In progress", "Recently added").
    var eyebrow: String? = nil
    var accent: (Color, Color)? = nil
    /// When set, a "See all" link appears on the right of the header.
    var seeAll: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ShelfHeader(title: title, eyebrow: eyebrow, accent: accent ?? theme.colors.palette[0], seeAll: seeAll)
                .padding(.horizontal, 4)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 32) {
                    content
                }
                .padding(.vertical, 30)   // room for the focus lift effect
                .padding(.horizontal, 4)
            }
            .scrollClipDisabled(barEdge == nil)
        }
    }
}

struct ShelfHeader: View {
    let title: String
    var eyebrow: String? = nil
    var accent: (Color, Color) = Theme.primary
    var seeAll: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                if let eyebrow {
                    Text(eyebrow.uppercased())
                        .font(.app(13, .heavy))
                        .kerning(1.6)
                        .foregroundStyle(accent.1)
                }
                Text(title)
                    .font(.app(24, .bold))
                    // Soft glow in the shelf's color
                    .shadow(color: accent.0.opacity(0.75), radius: 14)
            }
            Spacer(minLength: 20)
            if let seeAll {
                Button(action: seeAll) {
                    HStack(spacing: 6) {
                        Text("See all")
                        Image(systemName: "chevron.right")
                            .font(.app(13, .bold))
                    }
                }
                .buttonStyle(.seeAll(tint: accent.1))
            }
        }
    }
}

// MARK: - Focus pill (the shared recipe for pill-shaped controls)

/// White fill with a black label when focused, the primary gradient when
/// `active`, translucent glass otherwise. The presets below cover every
/// pill-shaped control in the app so the focus feel stays consistent.
struct FocusPillStyle: ButtonStyle {
    var active = false
    var font: Font = .app(18, .semibold)
    var idleText: Color = .white.opacity(0.75)
    /// Label colour when focused; destructive pills keep their tint instead of black.
    var focusText: Color = .black
    var idleFill: Color = .white.opacity(0.09)
    /// Hairline border while idle; nil for none.
    var idleStroke: Color? = nil
    /// Fixed control size (icon buttons); nil sizes the pill from `padding`.
    var size: CGSize? = nil
    var padding = CGSize(width: 20, height: 11)
    var focusScale: CGFloat = 1.06

    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(font)
            .foregroundStyle(focused ? focusText : (active ? .white : idleText))
            .padding(.vertical, size == nil ? padding.height.scaled : 0)
            .padding(.horizontal, size == nil ? padding.width.scaled : 0)
            .frame(width: size?.width.scaled, height: size?.height.scaled)
            .background(
                Capsule().fill(
                    focused
                        ? AnyShapeStyle(Color.white)
                        : (active
                            ? AnyShapeStyle(Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing))
                            : AnyShapeStyle(idleFill))
                )
            )
            .overlay(Capsule().stroke((idleStroke ?? .clear).opacity(focused || active ? 0 : 1), lineWidth: 1))
            .scaleEffect(focused ? focusScale : (configuration.isPressed ? 0.96 : 1))
            .animation(.easeOut(duration: 0.12), value: focused)
            .pointerHover()
    }
}

extension ButtonStyle where Self == FocusPillStyle {
    /// Season picker and other selectable pills.
    /// A studio or network at the end of the details line: plain words like
    /// the rest of the line until highlighted, then white like any control.
    static var studio: FocusPillStyle {
        FocusPillStyle(font: .app(18),
                       idleText: Theme.textSecondary,
                       idleFill: .clear,
                       padding: CGSize(width: 12, height: 6),
                       focusScale: 1.08)
    }

    static func pill(selected: Bool) -> FocusPillStyle {
        FocusPillStyle(active: selected,
                       font: .app(20, selected ? .bold : .regular),
                       idleText: Theme.textSecondary,
                       idleFill: .white.opacity(0.08),
                       padding: CGSize(width: 24, height: 10),
                       focusScale: 1.05)
    }

    /// Library filter-bar chips.
    static func chip(active: Bool) -> FocusPillStyle {
        FocusPillStyle(active: active, idleStroke: .white.opacity(0.14))
    }

    /// Shelf-header "See all" link.
    static func seeAll(tint: Color) -> FocusPillStyle {
        FocusPillStyle(font: .app(17, .semibold),
                       idleText: .white.opacity(0.7),
                       idleFill: tint.opacity(0.14),
                       idleStroke: tint.opacity(0.35),
                       padding: CGSize(width: 18, height: 8))
    }

    /// Small round icon button (hero pause etc.); 46×46 makes the capsule a circle.
    static var circleIcon: FocusPillStyle {
        FocusPillStyle(font: .app(16, .bold),
                       idleText: .white,
                       idleFill: .black.opacity(0.35),
                       idleStroke: .white.opacity(0.35),
                       size: CGSize(width: 46, height: 46),
                       focusScale: 1.1)
    }

    /// Detail-page action buttons (watched / favorite / next).
    static func action(active: Bool) -> FocusPillStyle {
        FocusPillStyle(active: active,
                       font: .app(20, .semibold),
                       idleText: .white,
                       idleFill: .white.opacity(0.12),
                       size: CGSize(width: 76, height: 52),
                       focusScale: 1.08)
    }

    /// Sign Out: ember, and still ember when focused so it never reads as ordinary.
    static var signOut: FocusPillStyle {
        let ember = Theme.palette[1].0
        return FocusPillStyle(font: .app(18, .semibold),
                              idleText: ember,
                              focusText: ember,
                              idleFill: ember.opacity(0.14),
                              idleStroke: ember.opacity(0.45),
                              padding: CGSize(width: 22, height: 10))
    }

    /// Translucent pill on gradient banners (Switch User).
    static var ghost: FocusPillStyle {
        FocusPillStyle(font: .app(17, .semibold),
                       idleText: .white,
                       idleFill: .white.opacity(0.16),
                       idleStroke: .white.opacity(0.4),
                       padding: CGSize(width: 22, height: 10),
                       focusScale: 1.05)
    }
}

// MARK: - Gradient action button (Play / Resume)

/// When select went down on a button, so a press held well past a click can
/// be let go without doing anything: the viewer has changed their mind.
@MainActor
final class PressTimer {
    private static let limit: TimeInterval = 1
    private var began: Date?

    func pressed(_ down: Bool) {
        if down { began = Date() }
    }

    /// Runs the action, unless the press that ended just now was held too long.
    func release(_ action: () -> Void) {
        defer { began = nil }
        if let began, Date().timeIntervalSince(began) > Self.limit { return }
        action()
    }
}

struct GradientButtonStyle: ButtonStyle {
    var colors: (Color, Color) = Theme.primary
    /// Told when select goes down, for a button that ignores a long hold.
    var timer: PressTimer? = nil
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, down in timer?.pressed(down) }
            .font(.app(22, .semibold))
            .padding(.vertical, CGFloat(12).scaled)
            .padding(.horizontal, CGFloat(28).scaled)
            // Focused, it turns white with dark words, like every other
            // control, and glows in its own colours underneath; no outline.
            .foregroundStyle(focused ? Color(red: 0.05, green: 0.05, blue: 0.08) : .white)
            .background {
                ZStack {
                    Capsule().fill(Theme.gradient(colors, start: .topLeading, end: .bottomTrailing))
                    Capsule().fill(.white).opacity(focused ? 1 : 0)
                }
            }
            // The colours swap at once; only the lift below animates. Faded,
            // the white half-covered the purple while the words were halfway
            // between dark and white, and the button blinked pale and blank
            // each time focus came or went.
            .transaction { $0.animation = nil }
            // Focused, the glow is an aura, centred on the button; idle, it is
            // a slight drop shadow.
            .shadow(color: colors.0.opacity(focused ? 0.65 : 0.25), radius: focused ? 26 : 10, y: focused ? 0 : 4)
            .scaleEffect(focused ? 1.07 : (configuration.isPressed ? 0.97 : 1))
            .animation(.easeOut(duration: 0.16), value: focused)
            .pointerHover(lift: 1.02)
    }
}

// MARK: - Tinted tag chip (genres etc.)

struct TagChip: View {
    let text: String
    var colors: (Color, Color) = Theme.primary

    var body: some View {
        Text(text)
            .font(.app(18))
            .foregroundStyle(.white)
            .padding(.vertical, CGFloat(7).scaled)
            .padding(.horizontal, CGFloat(16).scaled)
            .background(colors.0.opacity(0.18), in: Capsule())
            .overlay(Capsule().stroke(colors.0.opacity(0.5), lineWidth: 1))
    }
}

// MARK: - Metadata pill row

struct MetadataRow: View {
    let item: BaseItem

    var body: some View {
        HStack(spacing: 14) {
            // A recording: when it went out. The server's year for it is
            // the show's (2001 for the news), not the showing's.
            if let aired = Recorded.aired(item) {
                Text(aired)
            } else if let year = item.productionYear {
                Text(String(year))
            }
            if let minutes = item.runtimeMinutes, !item.isSeries {
                Text(ItemMenuPanel.runtime(minutes))
            }
            if let rating = item.officialRating {
                Text(rating)
                    .padding(.horizontal, CGFloat(8).scaled)
                    .padding(.vertical, CGFloat(2).scaled)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.4), lineWidth: 1))
            }
            if let community = item.communityRating {
                HStack(spacing: 4) {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                    Text(String(format: "%.1f", community))
                }
            }
        }
        .font(.app(18))
        .foregroundStyle(Theme.textSecondary)
    }
}

// MARK: - Media badges

/// The file's format at a glance: resolution, HDR, codecs, container, bitrate.
/// Outlined like the rating box in MetadataRow; the HDR format glows amber.
struct MediaBadges: View {
    let summary: MediaSummary

    var body: some View {
        HStack(spacing: 8) {
            if let resolution = summary.resolution { badge(resolution) }
            if let hdr = summary.hdr { badge(hdr, tint: Theme.palette[1].1) }
            ForEach(summary.details, id: \.self) { badge($0) }
        }
    }

    private func badge(_ text: String, tint: Color? = nil) -> some View {
        Text(text)
            .font(.app(15, .semibold))
            .foregroundStyle(tint ?? .white.opacity(0.75))
            .padding(.horizontal, CGFloat(9).scaled)
            .padding(.vertical, CGFloat(3).scaled)
            .overlay(RoundedRectangle(cornerRadius: 5)
                .stroke((tint ?? .white).opacity(tint == nil ? 0.35 : 0.7), lineWidth: 1))
    }
}

// MARK: - Wordmark

/// "Jelly" in a lighter gradient-filled weight, "Goose" heavy and white.
struct GooseWordmark: View {
    @Environment(\.appTheme) private var theme
    var size: CGFloat = 26

    var body: some View {
        HStack(spacing: 0) {
            Text(verbatim: "Jelly")
                .font(.app(size, .semibold))
                .foregroundStyle(Theme.gradient(theme.colors.palette[0], start: .leading, end: .trailing))
            Text(verbatim: "Goose")
                .font(.app(size, .black))
                .foregroundStyle(.white)
        }
        .kerning(-size * 0.025)
        .shadow(color: theme.colors.palette[0].0.opacity(0.35), radius: size * 0.35)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("JellyGoose")
    }
}
