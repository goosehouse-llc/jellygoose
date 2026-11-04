#if os(tvOS)
import SwiftUI

/// One row of the Apple TV's Home: its cards, and where its See all goes.
struct SpotlightRowData: Identifiable {
    enum Kind: Equatable {
        case landscape(removesFromNextUp: Bool)
        case posters
        /// Television channels, each with what's on it now.
        case live
        /// Music: albums, or songs, square.
        case squares
    }

    let id: String
    let title: String
    let eyebrow: String
    /// Which of the theme's colour pairs the row wears. An index, not the
    /// colours, since the rows are kept (HomeShelves) across a change of theme.
    let accentIndex: Int
    let kind: Kind
    let items: [BaseItem]
    let seeAll: HomeRoute

    /// A card's focus identity: its row's and its own, since a film can be in
    /// Continue Watching and Recently added at once.
    func focusID(_ item: BaseItem) -> String { id + "|" + item.id }
    var seeAllFocusID: String { id + "|*all" }
    var firstFocusID: String { items.first.map(focusID) ?? seeAllFocusID }

    func holds(_ focusID: String) -> Bool {
        focusID == seeAllFocusID || items.contains { self.focusID($0) == focusID }
    }

    /// What would change how the row looks, worked out once rather than on
    /// every comparison. Items compare by id alone, so their watched state
    /// goes in too, and for a channel what's on it and whether that's set
    /// to record.
    let signature: [String]

    init(id: String, title: String, eyebrow: String, accentIndex: Int, kind: Kind, items: [BaseItem],
         seeAll: HomeRoute) {
        self.id = id
        self.title = title
        self.eyebrow = eyebrow
        self.accentIndex = accentIndex
        self.kind = kind
        self.items = items
        self.seeAll = seeAll
        signature = items.map {
            "\($0.id)|\($0.progressFraction ?? -1)|\($0.userData?.played == true)|\($0.userData?.unplayedItemCount ?? -1)|\($0.currentProgram?.id ?? "")"
                + "|\($0.currentProgram?.timerId ?? "")|\($0.currentProgram?.seriesTimerId ?? "")"
        }
    }
}

/// What the top of the Apple TV's Home describes: the highlighted card, once
/// focus has settled on it and its picture is ready. Watched only by that
/// picture and the words over it, so a change redraws those and nothing else.
@MainActor
final class SpotlightModel: ObservableObject {
    struct Shown {
        let item: BaseItem
        /// The picture's address: two episodes showing their show's backdrop
        /// don't fade between the same picture.
        let backdropKey: String?
        let backdrop: UIImage?
        /// For a channel: the show or film that's on, as the library has it,
        /// whose logo heads the words.
        var title: BaseItem? = nil
    }

    @Published private(set) var shown: Shown?
    private var pending: Task<Void, Never>?
    private var warming: Task<Void, Never>?

    /// Shows `item` a moment after focus stops on it, so passing along a row
    /// doesn't turn the picture over for every card, and only once its picture
    /// and logo are on hand, so they arrive together with its words. `warm` is
    /// the pictures a press away, made ready once this one is showing.
    /// A picture found late for the card that's showing without one: a
    /// recording's cover, which takes asking the server what it's of.
    func dress(_ item: BaseItem, backdrop: URL, title: BaseItem? = nil) {
        let arriving = pending
        Task { [weak self] in
            await arriving?.value
            let image = await Self.backdrop(backdrop)
            guard let self, let image, self.shown?.item.id == item.id,
                  self.shown?.item.currentProgram?.id == item.currentProgram?.id, self.shown?.backdrop == nil else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.shown = Shown(item: item, backdropKey: backdrop.absoluteString, backdrop: image, title: title)
            }
        }
    }

    /// Nothing to describe: Home has no rows.
    func clear() {
        pending?.cancel()
        pending = nil
        if shown != nil { shown = nil }
    }

    func show(_ item: BaseItem, backdrop: URL?, logo: URL?, title: BaseItem? = nil, settle: Bool, warm: [URL] = []) {
        pending?.cancel()
        pending = nil
        warming?.cancel()
        // The same card again, unless it's a channel that has gone on to its
        // next programme: the card is the channel's, and what's said of it
        // up here is the programme's.
        guard shown?.item.id != item.id || shown?.item.currentProgram?.id != item.currentProgram?.id else {
            warmUp(warm)
            return
        }
        pending = Task { [weak self] in
            if settle {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            async let picture = Self.backdrop(backdrop)
            async let mark = Self.logo(logo)
            let (image, _) = await (picture, mark)
            guard !Task.isCancelled, let self else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                self.shown = Shown(item: item, backdropKey: image == nil ? nil : backdrop?.absoluteString,
                                   backdrop: image, title: title)
            }
            self.pending = nil
            self.warmUp(warm)
        }
    }

    /// The pictures either side, faded ahead of time, one at a time and
    /// behind anything wanted now, so moving on finds the next one ready.
    private func warmUp(_ urls: [URL]) {
        warming?.cancel()
        guard !urls.isEmpty else { return }
        warming = Task.detached(priority: .utility) {
            for url in urls {
                guard !Task.isCancelled else { return }
                _ = await ImagePipeline.spotlightBackdrop(url)
            }
        }
    }

    private nonisolated static func backdrop(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await ImagePipeline.spotlightBackdrop(url)
    }

    private nonisolated static func logo(_ url: URL?) async -> UIImage? {
        guard let url else { return nil }
        return await ImagePipeline.load(url)
    }
}

/// The Apple TV's Home, laid out the way Plezy's is: the highlighted title's
/// picture and details across the top, and the rows in a band beneath it.
///
/// The focus engine moves between rows, as everywhere on the Apple TV (so a
/// click on the remote's edge and a swipe both work), but only into the rows
/// either side of the band's: the rest are held out of focus, and the band
/// itself doesn't scroll, so focus can't wander off. Landing in another row,
/// that row glides to the same place every time. Coming back into Home, from
/// the menu, a film's page or the player, lands on the card last visited.
/// The top follows focus from layers of its own, so moving along a row redraws
/// two cards and, a beat later, the picture.
struct SpotlightHome: View {
    /// Where the band starts, below the title's details.
    static let bandTop: CGFloat = 560
    static let posterWidth = Theme.posterWidth * 0.8
    /// A square card's side: an album's cover, a song's.
    static let squareSide = Theme.posterWidth
    /// The picture across the top right, three quarters of the screen wide.
    static let backdropSize = CGSize(width: 1920 * 0.72, height: 1920 * 0.72 * 9 / 16)

    let rows: [SpotlightRowData]
    /// Held, not watched: where the band was, and what the top shows, outlive
    /// this view as the menu switches sections. Whether the band is below its
    /// first row is noted there too, for back.
    let shelves: HomeShelves
    /// Incremented by the parent to ask for the top row (back from a lower one).
    let scrollToTopRequest: Int
    let play: (BaseItem) -> Void
    let showDetails: (BaseItem) -> Void
    let seeAll: (HomeRoute) -> Void

    @Environment(\.appState) private var app
    @Environment(\.displayScale) private var displayScale
    @FocusState private var focus: String?
    /// The row in the band.
    @State private var activeRow: String?
    /// The rows held out of focus are those two or more from this one: the
    /// band's row, caught up a moment after each move, so holding and letting
    /// go of a row's cards (a cost for every card) never delays a press.
    @State private var lockCenter: String?
    /// A row focus is being sent to (back to the top row), taking focus until
    /// it arrives.
    @State private var pendingRow: String?
    /// The band's scroll, which jumps to the band's row (see `arrive`).
    @State private var scrollRow: String?
    /// The glide: the rows drawn this far from where the scroll put them,
    /// easing to nothing.
    @State private var glideOffset: CGFloat = 0
    /// Each row's height, for how far a glide goes.
    @State private var rowHeights: [String: CGFloat] = [:]
    /// Whether focus is in the band. While it's elsewhere (the menu, a pushed
    /// page, the player) only the landing card of the band's row takes focus,
    /// so coming back lands there, not on whichever card is nearest.
    @State private var bandFocused = false
    /// Whether this Home has been set up: once for each time it's made.
    @State private var begun = false

    init(rows: [SpotlightRowData], shelves: HomeShelves, scrollToTopRequest: Int,
         play: @escaping (BaseItem) -> Void, showDetails: @escaping (BaseItem) -> Void,
         seeAll: @escaping (HomeRoute) -> Void) {
        self.rows = rows
        self.shelves = shelves
        self.scrollToTopRequest = scrollToTopRequest
        self.play = play
        self.showDetails = showDetails
        self.seeAll = seeAll
        _activeRow = State(initialValue: shelves.spotlightRow)
        _lockCenter = State(initialValue: shelves.spotlightRow)
        _scrollRow = State(initialValue: shelves.spotlightRow)
    }

    /// A row's glide to the top of the band.
    private static let glide = Animation.easeOut(duration: 0.35)
    /// How far the band reaches below the screen, for the glide up a row.
    private static let glideReach: CGFloat = 520

    var body: some View {
        ZStack(alignment: .topLeading) {
            SpotlightBackdrop(model: shelves.spotlight)
            band
            SpotlightCover(model: shelves.spotlight)
            SpotlightInfo(model: shelves.spotlight)
            menuCatch
        }
        .pageSides()
        // Heard by a view of its own: read here, every step along a row ran
        // this whole body again.
        .background { FocusWatcher(focus: $focus) { _, id in focusMoved(to: id) } }
        .onChange(of: rows.map(\.id), initial: true) { old, _ in reconcile(previous: old) }
        // A channel's card stays as its programmes change under it: the top
        // is told again, or it went on naming the one that's over.
        .onChange(of: rows.first { $0.id == activeRow }?.kind == .live ? rows.first { $0.id == activeRow }?.signature : nil) { _, _ in
            guard let row = rows.first(where: { $0.id == activeRow }), let shown = shelves.spotlight.shown?.item.id,
                  let fresh = row.items.first(where: { $0.id == shown }) else { return }
            spotlight(fresh, in: row, settle: false)
        }
        .onChange(of: scrollToTopRequest) { _, _ in
            if let first = rows.first { go(to: first) }
        }
    }

    // MARK: In from the menu

    /// What focus knows the catch by.
    private static let catchID = "*catch"
    /// Where the catch starts: clear of the open menu.
    private static let catchLeading: CGFloat = 250

    /// Somewhere for a press right from the menu to land while the band's
    /// row is one of posters. A poster at the start of its row lies wholly
    /// under the open menu, which isn't to the right of the menu's rows; and
    /// with that poster the only card taking focus (see `onlyFocusable`), the
    /// press went nowhere. Nothing to see: focus goes on from here to the
    /// card at once (see `focusMoved`). A row of wider cards reaches out from
    /// under the menu and needs none.
    @ViewBuilder
    private var menuCatch: some View {
        if !bandFocused, pendingRow == nil,
           let row = rows.first(where: { $0.id == activeRow }) ?? rows.first, row.kind == .posters || row.kind == .squares {
            Color.clear
                .focusable()
                .focused($focus, equals: Self.catchID)
                .padding(.leading, Self.catchLeading)
        }
    }

    /// Focus has landed on the catch: on to the band's card. Should the card
    /// not take it, the row's cards are all let go, and the catch with them,
    /// so focus falls to one of them.
    private func passOn() {
        Task { @MainActor in
            for _ in 0..<10 {
                guard focus == Self.catchID else { return }
                focus = landingTarget
                try? await Task.sleep(for: .milliseconds(40))
            }
            if focus == Self.catchID { bandFocused = true }
        }
    }

    // MARK: The band

    private var band: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(rows) { row in
                    let held = isHeld(row)
                    EquatableView(content: SpotlightRowView(row: row, onlyFocusable: onlyFocusable(in: row),
                                                            focus: $focus, play: play, showDetails: showDetails,
                                                            seeAll: seeAll))
                        // The newest of the server's recordings can be
                        // deleted from their row here too.
                        .environment(\.recordingsDeletable, holdsRecordings(row))
                        // A recording with no picture of its own wears the
                        // guide's, as in its library: blank cards otherwise.
                        .environment(\.borrowsGuideArt, recordsInto(row))
                        // Where the row sits is applied around it, not in it:
                        // passed in, every move rebuilt both rows' every card.
                        .disabled(held)
                        // The whole row's width is a target for up and down,
                        // so a short row (Next Up) is reached from under the
                        // far end of a long one.
                        .focusSection()
                        // A held row's sideways scroll is off too: on, it offers
                        // the focus engine an invisible place to land.
                        .scrollDisabled(held)
                        // Rows beneath dimmed; rows above are drawn in full under
                        // the cover (SpotlightCover), where the focus engine can
                        // still reach them. Only the fade animates: animating
                        // the rest (what may take focus) lost focus.
                        .animation(.easeOut(duration: 0.25)) {
                            $0.opacity(isBelow(row) ? 0.5 : 1)
                        }
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowHeights[row.id] = $0 }
                        .id(row.id)
                }
                // Room under the last row, so it too can rise to the top.
                Color.clear.frame(height: 720 + Self.glideReach)
            }
            .padding(.horizontal, Theme.pageMargin)
            .scrollTargetLayout()
        }
        // Moved by the app alone, a row at a time: the focus engine scrolling it
        // to wherever it found a card is what made Home jump by a different
        // amount each time.
        .scrollPosition(id: $scrollRow, anchor: .top)
        // The rows above the band's stay inside the scroll view, faded out,
        // rather than scrolled off its top: out of its bounds, a row can't
        // always take focus.
        .safeAreaPadding(.top, Self.bandTop)
        .scrollDisabled(true)
        // The glide moves the whole scroll view, outside what it scrolls: on
        // its rows, the offset moved the rows it scrolls to as well, and the
        // two fought. It reaches below the screen, so moving up a row never
        // shows its bottom edge.
        .padding(.bottom, -Self.glideReach)
        .offset(y: glideOffset)
        .focusSection()
    }

    private func index(of rowID: String?) -> Int? {
        rowID.flatMap { id in rows.firstIndex { $0.id == id } }
    }

    /// Whether a row is what's new in a library the server records into,
    /// from which this account may delete.
    private func holdsRecordings(_ row: SpotlightRowData) -> Bool {
        if case .library(let library) = row.seeAll { return app?.recordingLibraries.contains(library.id) ?? false }
        return false
    }

    /// Whether a row is what's new in a library the server records into.
    private func recordsInto(_ row: SpotlightRowData) -> Bool {
        if case .library(let library) = row.seeAll { return app?.recordingFolders.contains(library.id) ?? false }
        return false
    }

    private func isBelow(_ row: SpotlightRowData) -> Bool {
        (index(of: row.id) ?? 0) > (index(of: activeRow) ?? 0)
    }

    /// Rows two or more from the band's are held out of focus, so the focus
    /// engine only ever moves to the rows either side.
    private func isHeld(_ row: SpotlightRowData) -> Bool {
        guard row.id != pendingRow, let position = index(of: row.id) else { return false }
        return abs(position - (index(of: lockCenter) ?? 0)) >= 2
    }

    /// While focus is outside the band, the band's row lets only its landing
    /// card take focus.
    private func onlyFocusable(in row: SpotlightRowData) -> String? {
        guard !bandFocused, pendingRow == nil, row.id == (activeRow ?? rows.first?.id) else { return nil }
        return landingTarget
    }

    /// The card last visited in the band's row, or its first.
    private var landingTarget: String? {
        guard let row = rows.first(where: { $0.id == activeRow }) ?? rows.first else { return nil }
        return rememberedTarget(in: row)
    }

    /// The card last visited in `row`, or its first. Its first, too, until
    /// this Home has been set up: what's remembered till then is of the Home
    /// before it (see `reconcile`).
    private func rememberedTarget(in row: SpotlightRowData) -> String {
        guard begun else { return row.firstFocusID }
        return shelves.spotlightFocus[row.id].flatMap { row.holds($0) ? $0 : nil } ?? row.firstFocusID
    }

    private func landingItem(in row: SpotlightRowData) -> BaseItem? {
        let target = rememberedTarget(in: row)
        return target == row.seeAllFocusID ? row.items.last : row.items.first { row.focusID($0) == target }
    }

    // MARK: Moving

    private func focusMoved(to id: String?) {
        guard let id else {
            // Gone from the band, unless it's only passing between two cards.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(120))
                if focus == nil, bandFocused { bandFocused = false }
            }
            return
        }
        if id == Self.catchID {
            passOn()
            return
        }
        let entering = !bandFocused
        if entering { bandFocused = true }
        guard let bar = id.firstIndex(of: "|"),
              let row = rows.first(where: { $0.id == id[..<bar] }) else { return }
        // On the way to the top row, passing through another.
        if let pendingRow, row.id != pendingRow { return }
        if pendingRow == row.id { pendingRow = nil }
        // Coming back into Home from the menu, the band's row offers only its
        // landing card, but the focus engine can also reach the rows either
        // side of it: from there, on to the landing card.
        if entering, pendingRow == nil, row.id != activeRow, let landingTarget {
            focus = landingTarget
            return
        }
        shelves.spotlightFocus[row.id] = id
        if row.id != activeRow {
            arrive(at: row)
        }
        // See all describes the card beside it, so the top never shows a card
        // from another row.
        let item = id == row.seeAllFocusID ? row.items.last : row.items.first { row.focusID($0) == id }
        if let item { spotlight(item, in: row, settle: true) }
    }

    /// Focus is in `row`: it becomes the band's, and glides to the top.
    ///
    /// The scroll jumps to the row, and the rows, drawn back where they were,
    /// ease into place. An animated scroll carried the focused card with it
    /// and the focus engine dropped it mid-flight, then put focus on the row's
    /// first card: a flicker on every move.
    private func arrive(at row: SpotlightRowData) {
        let from = activeRow
        let distance = from.map { top(of: row.id) - top(of: $0) } ?? 0
        // Unanimated: animating which row is the band's dropped focus too. The
        // rows fade in and out by themselves.
        pendingRow = nil
        activeRow = row.id
        var jump = Transaction()
        jump.disablesAnimations = true
        withTransaction(jump) {
            scrollRow = row.id
            glideOffset = distance
        }
        Task { @MainActor in
            // Once the jump is on screen.
            try? await Task.sleep(for: .milliseconds(1))
            withAnimation(Self.glide) { glideOffset = 0 }
            // The rows held out of focus catch up after the press is answered.
            try? await Task.sleep(for: .milliseconds(30))
            if activeRow == row.id { lockCenter = row.id }
        }
        shelves.spotlightRow = row.id
        shelves.scrolledDown = row.id != rows.first?.id
        prefetch(row)
    }

    /// Where a row starts in the band, from the heights of those above it.
    private func top(of rowID: String) -> CGFloat {
        guard let index = rows.firstIndex(where: { $0.id == rowID }) else { return 0 }
        return rows[..<index].reduce(0) { $0 + (rowHeights[$1.id] ?? 0) + 8 }
    }

    /// Sends focus to `row` (Back, from a lower row, to the top one), onto
    /// the card last visited there. The row is brought into place first, and
    /// let go of at once: two or more rows up it was outside the scroll view,
    /// where the Apple TV won't put focus, so Back fell through to the menu.
    /// Tried again for a moment until focus has landed.
    private func go(to row: SpotlightRowData) {
        let target = rememberedTarget(in: row)
        guard row.id != activeRow else {
            focus = target
            return
        }
        app?.holdMenuFocus()
        arrive(at: row)
        lockCenter = row.id
        pendingRow = row.id
        Task { @MainActor in
            for attempt in 0..<15 {
                // Landed (focusMoved clears it).
                guard pendingRow == row.id else { return }
                focus = attempt < 8 ? target : row.firstFocusID
                try? await Task.sleep(for: .milliseconds(40))
            }
            if pendingRow == row.id { pendingRow = nil }
        }
    }

    /// Keeps the band on a row that exists: on first showing, and when rows
    /// come and go (the last of Next Up removed, a library emptied).
    private func reconcile(previous: [String]) {
        guard !rows.isEmpty else { return }
        if !begun {
            // A Home made anew, come back to from another section, has every
            // row at its start again, whichever of its cards was visited
            // last. One far along, the See all of what's on now that led to
            // Live TV, is out of sight there and can't take focus; and with
            // it the only card that may (see `onlyFocusable`), nothing on
            // Home could: a press right from the menu did nothing, and Home
            // seemed dead. The rows are come back to at their first cards.
            // What's remembered isn't looked at until this is done (see
            // `rememberedTarget`): the rows were drawn before it, and
            // clearing what they'd read wouldn't draw them again.
            let stale = !shelves.spotlightFocus.isEmpty
            shelves.spotlightFocus.removeAll()
            begun = true
            if stale, let row = rows.first(where: { $0.id == activeRow }) ?? rows.first, let item = landingItem(in: row) {
                spotlight(item, in: row, settle: false)
            }
        }
        if activeRow == nil || !rows.contains(where: { $0.id == activeRow }) {
            // The row that took its place, or the top one.
            let old = activeRow.flatMap { previous.firstIndex(of: $0) } ?? 0
            let row = rows[min(old, rows.count - 1)]
            activeRow = row.id
            lockCenter = row.id
            scrollRow = row.id
            shelves.spotlightRow = row.id
            // Focus was in the row that went (a refresh holds the menu off
            // meanwhile): into the one in its place.
            if focus == nil, app?.menuFocusHeld == true { focus = landingTarget }
        } else if !previous.isEmpty, previous != rows.map(\.id), let active = activeRow {
            // A row came or went with the band's own still there: what's on
            // now arrives after the rest, above the libraries' rows. Above
            // the band's, it moved everything under it down a row's height
            // with the band left where it was: the new row stood in the
            // band's place looking like its row, focus went to a card of
            // the old one, out of sight below, and a press right from the
            // menu seemed to do nothing.
            if !bandFocused, shelves.spotlightFocus.isEmpty, let first = rows.first, first.id != active {
                // Nobody has been anywhere on Home yet: it begins at its
                // top row, whichever of them was last to arrive.
                activeRow = first.id
                lockCenter = first.id
                scrollRow = first.id
                shelves.spotlightRow = first.id
                if let item = landingItem(in: first) { spotlight(item, in: first, settle: false) }
            } else {
                // The band is put back on its row. Told the row it already
                // has, the scroll does nothing, so it's told none and then
                // that one again.
                var jump = Transaction()
                jump.disablesAnimations = true
                withTransaction(jump) { scrollRow = nil }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(1))
                    guard activeRow == active else { return }
                    withTransaction(jump) { scrollRow = active }
                }
            }
        }
        shelves.scrolledDown = activeRow != rows.first?.id
        guard let row = rows.first(where: { $0.id == activeRow }) else { return }
        if shelves.spotlight.shown == nil, let item = landingItem(in: row) {
            spotlight(item, in: row, settle: false)
        }
        prefetch(row)
    }

    // MARK: The top

    private func spotlight(_ item: BaseItem, in row: SpotlightRowData, settle: Bool) {
        let backdrop = backdropURL(item)
        shelves.spotlight.show(item, backdrop: backdrop, logo: logoURL(item), title: knownTitle(item), settle: settle,
                               warm: neighbours(of: item, in: row).compactMap(backdropURL))
        // Music has no recording's cover or channel's programme to look for.
        if item.isMusic || item.isAudiobook { return }
        // A recording's cover goes ahead of a backdrop that's only a frame the
        // server took from it (see `backdropURL`): asked for where not known.
        guard let app, backdrop == nil || (item.lacksPoster && app.knownRecordingCover(for: item) == nil) else { return }
        // Nothing to show behind it yet. A channel: what's on it, as its own
        // page shows it, which takes asking the library for it. A recording
        // perhaps: its cover. Either joins the words when it's found.
        Task {
            if let program = item.currentProgram?.program {
                let title = await app.libraryTitle(for: program)
                guard let picture = liveBackdrop(item, title: title) else { return }
                shelves.spotlight.dress(item, backdrop: picture, title: title)
            } else if let cover = await app.recordingCover(for: item) {
                shelves.spotlight.dress(item, backdrop: Self.picture(of: cover), title: cover.title)
            }
        }
    }

    /// The library's show or film for what's on a channel, or for a
    /// recording, where it's been asked.
    private func knownTitle(_ item: BaseItem) -> BaseItem? {
        if let program = item.currentProgram?.program { return app?.knownLibraryTitle(for: program) ?? nil }
        return app?.knownRecordingCover(for: item)?.title
    }

    /// A recording's picture: its show's backdrop as it is, or a cover made
    /// into one.
    private static func picture(of cover: RecordingCover) -> URL {
        cover.title == nil ? ImagePipeline.asCover(cover.url) : cover.url
    }

    /// A channel's picture: the backdrop of the show or film that's on, as
    /// its page has it; or else the listings' picture of the programme,
    /// whole, as a cover.
    private func liveBackdrop(_ channel: BaseItem, title: BaseItem?) -> URL? {
        if let title, let backdrop = app?.client?.imageURL(for: title, type: "Backdrop",
                                                            maxWidth: Theme.pixels(Self.backdropSize.width, scale: displayScale)) {
            return backdrop
        }
        return app?.client?.liveProgramImageURL(on: channel, maxWidth: 1280).map(ImagePipeline.asCover)
    }

    /// The cards a press away: either side along the row, and the ones above
    /// and below.
    private func neighbours(of item: BaseItem, in row: SpotlightRowData) -> [BaseItem] {
        var near: [BaseItem] = []
        let position = row.items.firstIndex(where: { $0.id == item.id }) ?? 0
        for other in [position + 1, position - 1, position + 2] where row.items.indices.contains(other) {
            near.append(row.items[other])
        }
        if let index = rows.firstIndex(where: { $0.id == row.id }) {
            for other in [index + 1, index - 1] where rows.indices.contains(other) {
                let items = rows[other].items
                if !items.isEmpty { near.append(items[min(position, items.count - 1)]) }
            }
        }
        return near
    }

    private func backdropURL(_ item: BaseItem) -> URL? {
        if item.isMusic || item.isAudiobook {
            // An artist's wide picture, where the server has one; else the
            // cover made into a backdrop (blurred across, whole in the corner).
            return app?.client?.imageURL(for: item, type: "Backdrop",
                                         maxWidth: Theme.pixels(Self.backdropSize.width, scale: displayScale))
                ?? app?.client?.imageURL(for: item, type: "Primary", maxWidth: 900).map(ImagePipeline.asCover)
        }
        if item.isLiveChannel {
            // What's on, where the library has been asked about it.
            guard let program = item.currentProgram?.program, let asked = app?.knownLibraryTitle(for: program) else { return nil }
            return liveBackdrop(item, title: asked)
        }
        // A recording: its show's backdrop, or the programme's picture, ahead
        // of a frame the server took from it.
        let cover = app?.knownRecordingCover(for: item).map(Self.picture)
        if item.lacksPoster, let cover { return cover }
        return app?.client?.imageURL(for: item, type: "Backdrop",
                                     maxWidth: Theme.pixels(Self.backdropSize.width, scale: displayScale))
            ?? cover
    }

    private func logoURL(_ item: BaseItem) -> URL? {
        app?.client?.imageURL(for: knownTitle(item) ?? item, type: "Logo", maxWidth: 600)
    }

    /// The row's pictures fetched ahead, undecoded, so moving along it finds
    /// them on the device rather than waiting on the server.
    private func prefetch(_ row: SpotlightRowData) {
        ImagePipeline.prefetch(row.items.compactMap(backdropURL) + row.items.compactMap(logoURL))
        // And the covers of its recordings, or what's on its channels, looked
        // for before any is landed on.
        if let app {
            for item in row.items where backdropURL(item) == nil && !item.isMusic && !item.isAudiobook {
                if let program = item.currentProgram?.program {
                    Task { _ = await app.libraryTitle(for: program) }
                } else {
                    Task { _ = await app.recordingCover(for: item) }
                }
            }
        }
    }
}

/// One row in the band. Equatable, so a focus move, a move to another row, or
/// another row changing never rebuilds it: only its own cards changing do.
/// Where it sits is applied around it (see `SpotlightHome.band`).
struct SpotlightRowView: View, Equatable {
    let row: SpotlightRowData
    /// Set while focus is outside the band: the one card that may take it.
    let onlyFocusable: String?
    var focus: FocusState<String?>.Binding
    let play: (BaseItem) -> Void
    let showDetails: (BaseItem) -> Void
    let seeAll: (HomeRoute) -> Void
    /// Read here, so a change of theme recolours the row by itself.
    @Environment(\.appTheme) private var theme

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.onlyFocusable == rhs.onlyFocusable
            && lhs.row.id == rhs.row.id && lhs.row.title == rhs.row.title
            && lhs.row.accentIndex == rhs.row.accentIndex
            && lhs.row.kind == rhs.row.kind && lhs.row.signature == rhs.row.signature
    }

    private var accent: (Color, Color) {
        let palette = theme.colors.palette
        return palette[row.accentIndex % palette.count]
    }

    var body: some View {
        Shelf(title: row.title, eyebrow: row.eyebrow, accent: accent) {
            ForEach(row.items) { item in
                card(item)
                    .disabled(onlyFocusable.map { $0 != row.focusID(item) } ?? false)
            }
            seeAllTile
                .disabled(onlyFocusable.map { $0 != row.seeAllFocusID } ?? false)
        }
    }

    @ViewBuilder
    private func card(_ item: BaseItem) -> some View {
        switch row.kind {
        case .landscape(let removesFromNextUp):
            LandscapeCard(item: item, showDetails: { showDetails(item) }, removesFromNextUp: removesFromNextUp,
                          focus: focus, focusID: row.focusID(item)) { play(item) }
        case .posters:
            PosterNavCard(item: item, width: SpotlightHome.posterWidth, focus: focus, focusID: row.focusID(item))
        case .live:
            LiveNowCard(item: item, focus: focus, focusID: row.focusID(item)) { play(item) }
        case .squares:
            if item.isAudiobook {
                ListeningCard(item: item, width: SpotlightHome.squareSide, focus: focus, focusID: row.focusID(item)) { play(item) }
            } else if item.isSong {
                SongCard(item: item, width: SpotlightHome.squareSide, focus: focus, focusID: row.focusID(item)) { play(item) }
            } else {
                AlbumCard(item: item, width: SpotlightHome.squareSide, focus: focus, focusID: row.focusID(item))
            }
        }
    }

    /// The row's See all, as its last card: with up and down moving between
    /// rows, a link up in the heading would be out of reach.
    private var seeAllTile: some View {
        let size = switch row.kind {
        case .landscape, .live: CGSize(width: Theme.landscapeWidth * 0.6, height: Theme.landscapeWidth * 9 / 16)
        case .posters: CGSize(width: SpotlightHome.posterWidth, height: SpotlightHome.posterWidth * 1.5)
        case .squares: CGSize(width: SpotlightHome.squareSide, height: SpotlightHome.squareSide)
        }
        return Button { seeAll(row.seeAll) } label: {
            VStack(spacing: 12) {
                Image(systemName: "chevron.right")
                    .font(.app(26, .bold))
                Text("See all")
                    .font(.app(19, .semibold))
            }
            .foregroundStyle(.white)
            .frame(width: size.width, height: size.height)
            .background(Theme.gradient(accent, start: .topLeading, end: .bottomTrailing).opacity(0.3))
            .keepsCardCorners()
        }
        .buttonStyle(.tvCard)
        .focused(focus, equals: row.seeAllFocusID)
    }
}

/// The highlighted title's picture across the top right. Its fade into the
/// page is baked into the image (`ImagePipeline.spotlightBackdrop`), so it
/// costs a plain picture to draw however much moves in front of it. It stays
/// put when the menu slides the page aside.
private struct SpotlightBackdrop: View {
    let model: SpotlightModel
    @Environment(\.menuShift) private var menuShift

    var body: some View {
        SpotlightPicture(model: model)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .offset(x: -menuShift)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/// The picture itself, crossfading as the highlighted card changes.
private struct SpotlightPicture: View {
    @ObservedObject var model: SpotlightModel

    var body: some View {
        ZStack {
            if let shown = model.shown, let image = shown.backdrop {
                Image(uiImage: image)
                    .resizable()
                    .frame(width: SpotlightHome.backdropSize.width, height: SpotlightHome.backdropSize.height)
                    .id(shown.backdropKey)
                    .transition(.opacity)
            }
        }
    }
}

/// The top of the page again, over the rows above the band's: the wallpaper
/// and the picture exactly as they are beneath, cut off where the band
/// starts. Those rows have to be where the focus engine can reach them (a
/// press up goes to the one just above), and it won't move to anything drawn
/// fainter than about 2%, which still showed; under this they can't be seen,
/// and a row gliding up or down passes under a clean edge. A library, with no
/// picture, has the wallpaper alone.
struct SpotlightCover: View {
    var model: SpotlightModel?
    /// Where the band starts, below the screen's top safe area.
    var bandTop: CGFloat = SpotlightHome.bandTop
    @Environment(\.menuShift) private var menuShift

    private static let screen = UIScreen.main.bounds.size
    /// The band's top is measured from under the screen's top safe area.
    private static let safeTop: CGFloat = UIApplication.shared.connectedScenes
        .compactMap { ($0 as? UIWindowScene)?.keyWindow?.safeAreaInsets.top }.first ?? 60

    var body: some View {
        // From the top of the screen (rows scroll up into its safe area too)
        // down to the band.
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.safeTop + bandTop)
            .overlay(alignment: .topTrailing) {
                // The whole screen's worth, pinned to the screen as the real
                // wallpaper and picture are.
                ZStack(alignment: .topTrailing) {
                    AppWallpaper(theme: Theme.selected)
                    if let model { SpotlightPicture(model: model) }
                }
                .frame(width: Self.screen.width, height: Self.screen.height, alignment: .topTrailing)
                .offset(x: -menuShift)
            }
            .clipped()
            .offset(y: -Self.safeTop)
            .allowsHitTesting(false)
    }
}

/// What the highlighted card is, as the banner used to show it: the pill,
/// the logo or title, the tagline and the details line. Bottom-aligned above
/// the band in a frame of its own, so nothing here moves the rows.
private struct SpotlightInfo: View {
    @ObservedObject var model: SpotlightModel
    @Environment(\.appState) private var app

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let item = model.shown?.item {
                details(item)
                    .id(item.id)
                    .transition(.opacity)
            }
        }
        .frame(width: 900, height: SpotlightHome.bandTop - 100, alignment: .bottomLeading)
        .padding(.top, 60)
        .padding(.leading, Theme.pageMargin + 4)
        .allowsHitTesting(false)
    }

    /// A channel: what's on it, when, and what the listings say of it.
    private func live(_ channel: BaseItem) -> some View {
        let program = channel.currentProgram?.program
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LiveBadge()
                Text(channel.liveChannelLine.uppercased())
                    .font(.app(14, .heavy))
                    .kerning(1.6)
                    .foregroundStyle(Theme.palette[2].1)
                    .lineLimit(1)
            }
            // Headed as the show's own page is: by its logo, where the library
            // has the show and the logo.
            if let title = model.shown?.title, let logo = app?.client?.imageURL(for: title, type: "Logo", maxWidth: 600) {
                HeroLogo(url: logo, fallback: program?.name ?? channel.displayTitle, tallest: 170)
            } else {
                Text(program?.name ?? channel.displayTitle)
                    .font(.app(40, .bold))
                    .lineLimit(2)
            }
            if let program {
                Text([LiveClock.span(program), program.isOn() ? LiveClock.left(program) : nil,
                      program.episodeTitle.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " · "))
                    .font(.app(20))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                LiveProgrammeAbout(program: program, font: .app(18), color: Theme.textSecondary, lines: 2)
            }
        }
    }

    @ViewBuilder
    private func details(_ item: BaseItem) -> some View {
        if item.isLiveChannel { live(item) } else if item.isMusic || item.isAudiobook { music(item) } else { title(item) }
    }

    /// An album or a song: what it is, its name, who it's by, and when.
    private func music(_ item: BaseItem) -> some View {
        let facts = [item.isSong ? item.album : nil, item.productionYear.map(String.init), item.genres?.first]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return VStack(alignment: .leading, spacing: 14) {
            Text((item.isAudiobook ? String(localized: "Audiobook", comment: "Kind of item, shown in capitals above its title")
                  : item.isSong ? String(localized: "Song", comment: "Kind of item, shown in capitals above its title")
                  : String(localized: "Album", comment: "Kind of item, shown in capitals above its title")).uppercased())
                .font(.app(14, .heavy))
                .kerning(1.6)
                .foregroundStyle(Theme.palette[3 % Theme.palette.count].1)
            Text(item.isAudiobook ? (item.album ?? item.displayTitle) : item.displayTitle)
                .font(.app(40, .bold))
                .lineLimit(2)
            if let artist = item.byLine {
                Text(artist)
                    .font(.app(24, .medium))
                    .lineLimit(1)
            }
            if !facts.isEmpty {
                Text(facts.joined(separator: " · "))
                    .font(.app(20))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
    }

    private func title(_ item: BaseItem) -> some View {
        let title = item.isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle
        return VStack(alignment: .leading, spacing: 14) {
            if let label = item.episodeLabel, item.resumeTicks > 0 {
                Text("CONTINUE · \(label.uppercased())")
                    .font(.app(14, .bold))
                    .kerning(1.2)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .background(Theme.primary.0.opacity(0.3), in: Capsule())
                    .overlay(Capsule().stroke(Theme.primary.0.opacity(0.65), lineWidth: 1))
            }
            // A recording's is its show's, where the library has the show.
            if let logo = app?.client?.imageURL(for: model.shown?.title ?? item, type: "Logo", maxWidth: 600) {
                HeroLogo(url: logo, fallback: title, tallest: 170)
            } else {
                Text(title)
                    .font(.app(40, .bold))
                    .lineLimit(2)
            }
            if !item.isEpisode,
               let tagline = item.taglines?.first?.trimmingCharacters(in: .whitespaces), !tagline.isEmpty {
                Text(tagline)
                    .font(.custom("Figtree-Italic", fixedSize: 22 * Theme.uiScale))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.6), radius: 8, y: 2)
                    .lineLimit(1)
            }
            if let label = item.episodeLabel {
                // Still to air: when, first.
                let when = AirDay.isComing(item) ? AirDay.of(item).map(AirDay.short) : nil
                Text([when, label, item.displayTitle].compactMap { $0 }.joined(separator: " · "))
                    .font(.app(20))
                    .foregroundStyle(Theme.textSecondary)
            } else {
                MetadataRow(item: item)
            }
        }
    }
}
#endif
