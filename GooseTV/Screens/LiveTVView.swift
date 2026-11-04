import SwiftUI
import Combine

/// What the Live TV page lists: the channels, and the guide for them over the
/// hours ahead. The programme that's highlighted is kept apart
/// (`LiveHighlight`), so that moving about the guide redraws the band over it
/// and not the guide.
@MainActor
final class LiveTVModel: ObservableObject {
    /// Which channels the guide lists; or, in the guide's place, the list of
    /// what's set to record.
    enum Filter: Hashable { case all, favourites, genre(LiveGenre), scheduled }

    /// How much of the day ahead the guide shows: twelve hours, where the
    /// server's listings go that far. (Many don't: a server keeps what its
    /// listings' source hands it, which may be a few hours.) Another length
    /// can be set by hand, in hours (`goosetv.liveTV.guideHours`), for
    /// trying it.
    static let span: TimeInterval = {
        let set = UserDefaults.standard.double(forKey: "goosetv.liveTV.guideHours")
        return (set > 0 ? set : 12) * 3600
    }()

    @Published private(set) var channels: [LiveChannel] = []
    /// Each channel's programmes in order, by the channel's id.
    @Published private(set) var guide: [String: [LiveProgram]] = [:]
    /// Where the guide begins: the half-hour that's under way.
    @Published private(set) var guideStart = LiveTVModel.halfHour(before: Date())
    /// The time, to the minute, for what depends on it.
    @Published private(set) var now = Date()
    @Published private(set) var loaded = false
    @Published var filter: Filter = .all
    /// Whether this account may set recordings; asked once.
    @Published private(set) var canRecord = false
    private var askedCanRecord = false
    /// What to say when a recording couldn't be set or taken off.
    @Published var recordingProblem: String?
    /// What the server is set to record, for the list of it: asked for when
    /// the list is opened, and again whenever it may have changed.
    @Published private(set) var timers: [LiveTimer] = []
    @Published private(set) var seriesTimers: [LiveSeriesTimer] = []
    @Published private(set) var timersLoaded = false

    /// Off for a model that's only there for the recordings the server has
    /// set (a library of recordings, away from the guide): what's changed
    /// is read back from the list of them, not the channels and the guide.
    var keepsGuide = true
    let tuner = LiveTuner()
    /// Multiview is up over the full screen, with the full screen's tuner
    /// let go: coming back to the app (from Control Center, say) isn't to
    /// tune it again underneath the wall.
    var wallUp = false
    let highlight = LiveHighlight()
    /// The time the viewer is at in the guide: where the programme focus is
    /// on begins, or now if that's behind. Kept as focus goes up and down,
    /// so that a column is what's gone down, whatever the lengths of the
    /// programmes on the way. Nothing is drawn from it.
    private(set) var cursor: Date?
    /// The channel focus is on, or was last.
    private(set) var cursorChannel: String?
    /// The programme focus is on, or was last: its block in the guide.
    private(set) var focusedBlock: String?
    /// Whether focus is in the guide now, on that programme, and not gone
    /// to the filters, the menu or the full screen.
    private(set) var guideHasFocus = false
    /// A channel to put focus on, on what it's showing now: the programme
    /// that had focus has gone from the guide under it (over, as the guide
    /// moved on to the next half-hour), or its channel's row has (unmarked
    /// as a favourite among the favourites), and nothing else says where
    /// focus should go instead. The Apple TV left to itself put it on
    /// whatever it found, the top of the guide or the menu.
    let lost = PassthroughSubject<String, Never>()
    /// A programme told to take focus, by its id.
    let summons = PassthroughSubject<String, Never>()
    /// What the guide's own scroll view is told to do (Apple TV): bring a
    /// channel's row into view from where the guide begins, or put focus
    /// on whatever programme lies at a place along a row. Rows by their
    /// place in the list, across in points from where the guide begins.
    enum GuideCall { case show(row: Int), focus(row: Int, across: CGFloat) }
    let rowCalls = PassthroughSubject<GuideCall, Never>()
    /// The programme focus was last sent to in place of where it was
    /// going, and when, until it's there.
    var refusal: (id: String, at: Date)?
    private var client: (any MediaServer)?
    private var settling: Task<Void, Never>?

    var shown: [LiveChannel] {
        switch filter {
        case .all, .scheduled: channels
        case .favourites: channels.filter(\.isFavorite)
        case .genre(let genre): channels.filter { current(on: $0).map(genre.has) ?? false }
        }
    }

    /// The kinds of programme on somewhere now: a chip for each, and none
    /// for a server with no guide.
    var genres: [LiveGenre] {
        LiveGenre.allCases.filter { genre in channels.contains { current(on: $0).map(genre.has) ?? false } }
    }

    var hasFavourites: Bool { channels.contains(where: \.isFavorite) }

    static func halfHour(before date: Date) -> Date {
        Date(timeIntervalSinceReferenceDate: (date.timeIntervalSinceReferenceDate / 1800).rounded(.down) * 1800)
    }

    /// What's on a channel now, by the guide where it has it.
    func current(on channel: LiveChannel) -> LiveProgram? {
        guide[channel.id]?.first { $0.isOn(at: now) } ?? channel.now.flatMap { $0.isOn(at: now) ? $0 : nil }
    }

    /// What follows it.
    func next(on channel: LiveChannel) -> LiveProgram? {
        guide[channel.id]?.first { $0.start > now }
    }

    /// The channels, then the guide for them. Asked again every few minutes:
    /// the guide moves on with the clock, and nothing says when.
    ///
    /// False if the server couldn't be asked for its channels: a page that
    /// has none to show yet asks again sooner for that.
    @discardableResult
    func load(from client: any MediaServer) async -> Bool {
        self.client = client
        if !askedCanRecord {
            askedCanRecord = true
            let may = await client.liveCanRecord()
            if may != canRecord { canRecord = may }
        }
        guard let found = try? await client.liveChannels() else {
            loaded = true
            return false
        }
        if found != channels { channels = found }
        loaded = true
        let start = Self.halfHour(before: Date())
        var listed: [String: [LiveProgram]] = [:]
        let ids = found.map(\.id)
        // A few dozen channels to a request: a tuner's worth in one or two,
        // and a long IPTV list not all in one answer.
        for from in stride(from: 0, to: ids.count, by: 60) {
            let some = Array(ids[from..<min(from + 60, ids.count)])
            guard let programs = try? await client.liveGuide(channelIds: some, from: start,
                                                             to: start.addingTimeInterval(Self.span)) else { continue }
            for program in programs {
                guard let channel = program.channelId else { continue }
                listed[channel, default: []].append(program)
            }
        }
        for channel in listed.keys { listed[channel]?.sort { $0.start < $1.start } }
        // A guide that couldn't be fetched this time leaves the last one up.
        if !listed.isEmpty || guide.isEmpty {
            if start != guideStart { guideStart = start }
            if listed != guide { guide = listed }
        }
        tick()
        // A filter with nothing left under it would be an empty page.
        if filter != .all, shown.isEmpty { filter = .all }
        if let id = highlight.channel?.id, let fresh = found.first(where: { $0.id == id }), fresh != highlight.channel {
            highlight.channel = fresh
        }
        if let id = highlight.playing?.id, let fresh = found.first(where: { $0.id == id }), fresh != highlight.playing {
            highlight.playing = fresh
        }
        // The programme at the top of the page as the guide has it now: set
        // to record since, perhaps.
        if let channel = highlight.channel?.id, let id = highlight.program?.id,
           let fresh = guide[channel]?.first(where: { $0.id == id }), fresh != highlight.program {
            highlight.program = fresh
        }
        if filter == .scheduled { await loadTimers() }
        return true
    }

    // The page gone with its full screen still over it (sent elsewhere by a
    // link) is never told it has disappeared with nothing in front of it,
    // and was left tuned: whatever else, the channel is let go when the
    // page's own state goes.
    deinit {
        let tuner = tuner
        Task { @MainActor in tuner.stop() }
    }

    func loadTimers() async {
        guard let client, let found = try? await client.liveScheduled() else {
            timersLoaded = true
            return
        }
        let ahead = found.timers.filter { $0.end > Date() }
        if ahead != timers { timers = ahead }
        if found.series != seriesTimers { seriesTimers = found.series }
        timersLoaded = true
    }

    /// Changes how a series is recorded: shown at once, sent, and read back
    /// from the server, which is what the list then goes by.
    func set(_ options: LiveSeriesOptions, for series: LiveSeriesTimer) {
        guard let client, options != series.options else { return }
        if let at = seriesTimers.firstIndex(where: { $0.id == series.id }) { seriesTimers[at].options = options }
        Task {
            do {
                try await client.liveSetSeries(timerId: series.id, options)
            } catch {
                recordingProblem = String(localized: "Couldn't change the recording.", comment: "Live TV: the server refused or didn't answer when asked to change how a series is recorded")
            }
            // The showings it sets are the server's to work out again.
            if keepsGuide { await load(from: client) } else { await loadTimers() }
        }
    }

    /// The list's rows by name, in the order they stand: the series, then
    /// the showings. What a row answers to when it's told to take focus.
    private var scheduledRows: [String] {
        seriesTimers.map { LiveScheduledAsked.series($0).id } + timers.map { LiveScheduledAsked.timer($0).id }
    }

    /// The filter that opens the list, by the same kind of name.
    static let scheduledChip = "scheduled"

    /// Takes a recording off the list: the showing a row stands for, or the
    /// series (a series' own row, or the series one of its episodes comes
    /// of), and with it every episode still to come.
    func cancel(_ row: LiveScheduledAsked, series: Bool) {
        guard let client else { return }
        let place = scheduledRows.firstIndex(of: row.id) ?? 0
        Task {
            do {
                switch row {
                case .timer(let timer):
                    if !series { try await client.liveCancelRecording(timerId: timer.id) }
                    else if let id = timer.seriesTimerId { try await client.liveCancelSeries(timerId: id) }
                case .series(let series):
                    try await client.liveCancelSeries(timerId: series.id)
                }
            } catch {
                recordingProblem = String(localized: "Couldn't cancel the recording.", comment: "Live TV: the server refused or didn't answer when asked to cancel a recording")
            }
            // The guide too: its red dots are the same recordings.
            if keepsGuide { await load(from: client) } else { await loadTimers() }
            // The row that had focus has gone, and focus with it, to nowhere
            // in particular: the row that's moved up into its place is told
            // to take it, or the filter over the list when the list is empty.
            let rows = scheduledRows
            try? await Task.sleep(for: .milliseconds(150))
            summons.send(rows.isEmpty ? Self.scheduledChip : rows.contains(row.id) ? row.id : rows[min(place, rows.count - 1)])
        }
    }

    /// What can be done about recording a programme; and, with one that's
    /// being recorded as it's on, about the recording: seen from its start.
    enum Recording { case fromStart, record, recordSeries, cancel, cancelSeries }

    /// Sets the server to record, or not to, and has the guide read again:
    /// which showings a recording covers is the server's to say (a series
    /// takes in every episode in the listings).
    func set(_ what: Recording, for program: LiveProgram) {
        guard let client else { return }
        if what == .fromStart { return fromStart(program) }
        Task {
            do {
                try await what.send(for: program, to: client)
            } catch {
                recordingProblem = what.failure
            }
            await load(from: client)
        }
    }

    /// The choices for a programme, in the order they're offered: none for
    /// one that's over, or for an account that may not record.
    func recordings(for program: LiveProgram?) -> [Recording] {
        guard let program else { return [] }
        let all = Recording.choices(for: program, at: now)
        // Anyone may watch what's being recorded; setting and stopping is
        // for an account that may record.
        return canRecord ? all : all.filter { $0 == .fromStart }
    }

    /// The programme from its beginning, by the recording the server is
    /// making of it: its channel is tuned, and the picture is the
    /// recording's first, not the broadcast as it goes out. Where the
    /// recording can't be had (it began this half-minute, or has just
    /// ended) the channel comes as it is, and that's said.
    func fromStart(_ program: LiveProgram, on known: LiveChannel? = nil) {
        guard let timer = program.timerId, let id = known?.id ?? program.channelId else { return }
        let found = known ?? channels.first { $0.id == id } ?? highlight.playing.flatMap { $0.id == id ? $0 : nil }
        guard let channel = found else { return }
        fromStart(timer: timer, on: channel)
    }

    func fromStart(timer: String, on channel: LiveChannel) {
        guard let client else { return }
        if highlight.playing != channel { highlight.playing = channel }
        Task {
            if let found = await client.liveRecording(timerId: timer) {
                tune(channel, from: found.recording)
            } else {
                tune(channel)
                recordingProblem = String(localized: "The recording can't be watched from its start just yet. Try again in a minute.",
                                          comment: "Live TV: the server has only just begun recording the programme, or has just finished, and its recording can't be read")
            }
        }
    }

    /// The recording the server is making for a timer, where it is.
    func recording(for timer: String) async -> LiveRecording? {
        await client?.liveRecording(timerId: timer)?.recording
    }

    func name(of what: Recording, for program: LiveProgram) -> String { what.name(for: program, at: now) }

    /// The minute has turned.
    func tick() {
        now = Date()
        // Past the half-hour, the guide begins at the next one: what's over
        // is no use to anybody.
        let start = Self.halfHour(before: now)
        if start != guideStart { guideStart = start }
        keepFocus()
    }

    /// Looks to whether the programme with focus is still in the guide,
    /// and says so where it isn't (see `lost`).
    private func keepFocus() {
        #if os(tvOS)
        guard guideHasFocus, filter != .scheduled, let block = focusedBlock, let id = cursorChannel else { return }
        let rows = shown
        if let channel = rows.first(where: { $0.id == id }) {
            if !holds(block, on: channel) { lost.send(id) }
        } else if !rows.isEmpty {
            // Its row has gone: the one that was next after it, or the last.
            let was = channels.firstIndex { $0.id == id } ?? 0
            let next = rows.first { row in (channels.firstIndex { $0.id == row.id } ?? 0) > was } ?? rows[rows.count - 1]
            lost.send(next.id)
        }
        #endif
    }

    /// Whether a block is still in a channel's row of the guide.
    func holds(_ block: String, on channel: LiveChannel) -> Bool {
        let listed = programs(on: channel)
        return listed.isEmpty ? block == "none-" + channel.id : listed.contains { $0.id == block }
    }

    /// What the guide has for a channel, from where it begins to where it ends.
    private func programs(on channel: LiveChannel) -> [LiveProgram] {
        let end = guideStart.addingTimeInterval(Self.span)
        return (guide[channel.id] ?? channel.now.map { [$0] } ?? []).filter { $0.end > guideStart && $0.start < end }
    }

    /// The viewer is on this programme: focus came to it, or it was tapped.
    /// What it is follows in a moment, so the top of the page isn't
    /// rewritten for every row passed over. The picture doesn't follow: it
    /// stays on the channel last tuned (see `tune`).
    func look(at channel: LiveChannel, program: LiveProgram?, settle: Bool = true) {
        settling?.cancel()
        settling = Task {
            if settle {
                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
            }
            // As the guide has them by now: what was handed over is the
            // programme as its row was last drawn, which a recording set a
            // moment ago has since changed.
            let channel = channels.first { $0.id == channel.id } ?? channel
            let program = program.map { drawn in guide[channel.id]?.first { $0.id == drawn.id } ?? drawn }
            if highlight.channel != channel { highlight.channel = channel }
            if highlight.program != program { highlight.program = program }
        }
    }

    /// Where the channel last tuned is kept: the guide opens on it, and
    /// Home's row of what's on begins with it.
    static let lastKey = "goosetv.liveTV.lastChannel"
    /// Where the viewer's last choice of channels is kept: all of them, the
    /// favourites, or the ones showing a kind of programme.
    static let filterKey = "goosetv.liveTV.filter"

    /// A choice made from the chips over the guide: shown, and kept for the
    /// next time the page is opened. Only what the viewer chose is kept, not
    /// where the page fell back to with nothing under the choice just then
    /// (no sport on, the last favourite unmarked): the choice comes back
    /// when there is. The list of recordings isn't kept either. It stands in
    /// the guide's place, and a page that opened on it would open on no
    /// channels at all.
    func choose(_ choice: Filter) {
        filter = choice
        switch choice {
        case .all: UserDefaults.standard.set("all", forKey: Self.filterKey)
        case .favourites: UserDefaults.standard.set("favourites", forKey: Self.filterKey)
        case .genre(let genre): UserDefaults.standard.set("genre:" + genre.rawValue, forKey: Self.filterKey)
        case .scheduled: break
        }
    }

    /// The choice last made, for the page as it opens, before its channels
    /// are asked for: loaded, a choice with nothing under it gives way to
    /// all the channels (see `load`).
    func restoreChoice() {
        guard filter == .all, let kept = UserDefaults.standard.string(forKey: Self.filterKey) else { return }
        if kept == "favourites" {
            filter = .favourites
        } else if kept.hasPrefix("genre:"), let genre = LiveGenre(rawValue: String(kept.dropFirst("genre:".count))) {
            filter = .genre(genre)
        }
    }

    /// The server to ask, for a model that tunes before it has loaded
    /// anything (the full screen opened from Home).
    func use(_ client: any MediaServer) { self.client = client }

    /// Tunes a channel: one chosen to watch, or stepped to with the picture
    /// full screen. It's the picture from then on, in the corner of the
    /// guide too, whatever is highlighted there, and what the page opens on
    /// the next time. Looking about the guide tunes nothing.
    func tune(_ channel: LiveChannel, after delay: Duration = .zero, from start: LiveRecording? = nil) {
        guard let client else { return }
        if highlight.playing != channel { highlight.playing = channel }
        UserDefaults.standard.set(channel.id, forKey: Self.lastKey)
        if tuner.channelId == channel.id {
            // Chosen again after it wouldn't come: asked for again. Or on
            // already, and wanted from the programme's beginning.
            tuner.retry()
            if let start { tuner.tune(to: channel.id, on: client, from: start) }
        } else {
            tuner.tune(to: channel.id, on: client, after: delay, from: start)
        }
    }

    /// The page opens on the channel last watched, where the server still
    /// has it, and on the first channel otherwise.
    func resume() {
        guard highlight.playing == nil, tuner.channelId == nil else { return }
        // Not for an app that's been put away since the page was asked for:
        // the channels may come back after it has, and a tuner taken then
        // was held for nobody until the app was next opened. It's tuned
        // when the app comes forward again (see the page's `scenePhase`).
        guard UIApplication.shared.applicationState != .background else { return }
        let last = UserDefaults.standard.string(forKey: Self.lastKey)
        if let channel = channels.first(where: { $0.id == last }) ?? channels.first { tune(channel) }
    }

    /// Focus is on this programme. Along a channel's row the time moves
    /// with it; come to from the row above or below, the time stays.
    func landed(on channel: LiveChannel, _ program: LiveProgram?, block: String) {
        focusedBlock = block
        guideHasFocus = true
        if let program {
            if channel.id == cursorChannel || cursor == nil { cursor = max(program.start, now) }
        } else if cursor == nil {
            // A channel with no listings has no times: now, then.
            cursor = now
        }
        cursorChannel = channel.id
        refusal = nil
    }

    /// Focus came into the guide from outside it: wherever it lands is
    /// where the viewer is.
    func forgetCursor() {
        cursor = nil
        cursorChannel = nil
    }

    /// Focus has left a programme: for the filters, the menu or the full
    /// screen, unless it's only gone to another programme, which says so
    /// itself (before this or after).
    func left(block: String) {
        if focusedBlock == block { guideHasFocus = false }
    }

    /// The programme in a channel's row that's on at the viewer's time, or
    /// the nearest to it where the listings have a gap there, and where it
    /// lies along the row.
    func cursorBlock(for channel: LiveChannel, in metrics: GuideMetrics) -> (id: String, span: ClosedRange<CGFloat>)? {
        guard let cursor else { return nil }
        // Not before now: the time may have been settled on a while ago.
        let at = metrics.width(of: max(cursor, now).timeIntervalSince(guideStart)) + 1
        var edge: CGFloat = 0
        var best: (id: String, span: ClosedRange<CGFloat>, off: CGFloat)?
        for block in blocks(for: channel, in: metrics) {
            let from = edge + block.lead, to = from + block.width + metrics.gap
            edge = to
            let off = at < from ? from - at : (at >= to ? at - to + 1 : 0)
            if best == nil || off < best!.off { best = (block.id, from...(from + block.width), off) }
        }
        return best.map { ($0.id, $0.span) }
    }

    /// The channel above or below in the list, round at the ends: channel
    /// up and down, with the picture full screen.
    func step(_ offset: Int) {
        let list = shown.isEmpty ? channels : shown
        guard !list.isEmpty else { return }
        let at = highlight.playing.flatMap { on in list.firstIndex { $0.id == on.id } } ?? 0
        let next = list[((at + offset) % list.count + list.count) % list.count]
        // Told at once, tuned in a moment: three presses are one channel change.
        tune(next, after: .milliseconds(450))
    }

    func toggleFavourite(_ channel: LiveChannel) {
        guard let client, let at = channels.firstIndex(where: { $0.id == channel.id }) else { return }
        let marked = !channels[at].isFavorite
        set(channel.id, favourite: marked)
        Task {
            // Taken back if the server wouldn't have it.
            if (try? await client.setFavorite(channel.id, marked)) == nil { set(channel.id, favourite: !marked) }
        }
    }

    private func set(_ id: String, favourite: Bool) {
        if let at = channels.firstIndex(where: { $0.id == id }) { channels[at].isFavorite = favourite }
        if highlight.channel?.id == id { highlight.channel?.isFavorite = favourite }
        if highlight.playing?.id == id { highlight.playing?.isFavorite = favourite }
        if filter == .favourites, shown.isEmpty { filter = .all }
        keepFocus()
    }

    /// A channel's row of the guide: its programmes from where the guide
    /// begins, each as wide as it is long. A channel with no listings is one
    /// block the width of the guide, so there's still something to choose.
    func blocks(for channel: LiveChannel, in metrics: GuideMetrics) -> [GuideBlock] {
        let end = guideStart.addingTimeInterval(Self.span)
        let listed = programs(on: channel)
        guard !listed.isEmpty else {
            return [GuideBlock(id: "none-" + channel.id, program: nil, lead: 0, width: metrics.width(of: Self.span) - metrics.gap)]
        }
        var blocks: [GuideBlock] = []
        var filled: CGFloat = 0
        for program in listed {
            let from = max(program.start, guideStart), to = min(program.end, end)
            let x = metrics.width(of: from.timeIntervalSince(guideStart))
            // Listings that overlap (two sources for one channel) keep the first.
            guard to > from, x >= filled - 1 else { continue }
            let width = max(metrics.width(of: to.timeIntervalSince(from)) - metrics.gap, metrics.least)
            blocks.append(GuideBlock(id: program.id, program: program, lead: max(x - filled, 0), width: width))
            filled = max(x, filled) + width + metrics.gap
        }
        return blocks
    }
}

@MainActor
final class LiveHighlight: ObservableObject {
    /// The channel the picture is of: the one last tuned, which isn't
    /// changed by looking about the guide.
    @Published var playing: LiveChannel?
    /// The channel of the programme the viewer is on in the guide.
    @Published var channel: LiveChannel?
    /// The programme focus is on: what's on now, or something later in the
    /// channel's row. Nil on a channel with no listings.
    @Published var program: LiveProgram?
}

/// One programme's place in a channel's row.
struct GuideBlock: Identifiable, Equatable {
    let id: String
    let program: LiveProgram?
    /// Empty guide before it: a gap in the listings.
    let lead: CGFloat
    let width: CGFloat
}

/// The guide's measures: a television's, a tablet's, a phone's.
struct GuideMetrics: Equatable {
    /// The channels' column, which stays put as the guide moves under it.
    let column: CGFloat
    let rowHeight: CGFloat
    let perMinute: CGFloat
    let gap: CGFloat = 6
    /// Clear space over the first channel's row and under the last.
    let edge: CGFloat = 6
    let rowGap: CGFloat = 8
    /// The narrowest a programme is drawn, however short it is.
    let least: CGFloat = 26

    func width(of seconds: TimeInterval) -> CGFloat { CGFloat(seconds / 60) * perMinute }
    var pitch: CGFloat { rowHeight + rowGap }

    static func make(narrow: Bool) -> GuideMetrics {
        narrow ? GuideMetrics(column: 90, rowHeight: 58, perMinute: 4.5)
               : GuideMetrics(column: CGFloat(152).scaled, rowHeight: CGFloat(76).scaled, perMinute: CGFloat(8).scaled)
    }

    /// What a row's head is filled with, the channel in the guide and the
    /// time in the list of recordings: the theme's own colour, thinned, so
    /// it reads as a different thing from the programmes' plain glass.
    static var headFill: some ShapeStyle { Theme.gradient(Theme.primary).opacity(0.34) }
}

/// A programme that's to come, and the channel it's on.
struct LiveAsked: Equatable {
    let channel: LiveChannel
    let program: LiveProgram
}

/// What's to be done with a programme: record it, record its series, or
/// (for one that isn't on yet) go to its channel as it is now. Asked of
/// what's on from the full screen, where there's no going to the channel:
/// it's the one on screen.
private struct LiveAsking: ViewModifier {
    let asked: LiveAsked?
    @Binding var isPresented: Bool
    let model: LiveTVModel
    let watch: ((LiveChannel) -> Void)?
    /// Asked from the guide, the programme's beginning is somewhere to go
    /// (the full screen); asked from the full screen, the picture goes back.
    var fromStart: ((LiveAsked) -> Void)? = nil

    func body(content: Content) -> some View {
        content.confirmationDialog(asked?.program.name ?? "", isPresented: $isPresented, titleVisibility: .visible, presenting: asked) { asked in
            ForEach(model.recordings(for: asked.program), id: \.self) { choice in
                Button(model.name(of: choice, for: asked.program), role: choice.undoes ? .destructive : nil) {
                    if choice == .fromStart, let fromStart { fromStart(asked) } else { model.set(choice, for: asked.program) }
                }
            }
            if let watch {
                Button(String(localized: "Watch \(asked.channel.name)", comment: "Live TV: goes to the channel a later programme is on, as it is now; the placeholder is the channel's name")) {
                    watch(asked.channel)
                }
            }
        } message: { asked in
            Text([LiveClock.span(asked.program), asked.channel.name].joined(separator: " · "))
        }
    }
}

extension View {
    /// The panel a series' row opens: over the page on a television, a
    /// sheet by touch.
    @ViewBuilder
    func seriesPanel(_ series: Binding<LiveSeriesTimer?>, model: LiveTVModel) -> some View {
        #if os(tvOS)
        fullScreenCover(item: series) { open in
            LiveSeriesPanel(model: model, id: open.id, first: open) { series.wrappedValue = nil }
                // All but opaque: the list under it read through the choices.
                .presentationBackground(Theme.background.opacity(0.97))
        }
        #else
        sheet(item: series) { open in
            LiveSeriesPanel(model: model, id: open.id, first: open) { series.wrappedValue = nil }
                .presentationDetents([.medium, .large])
                .presentationBackground(Theme.background)
        }
        #endif
    }
}

/// How a series is recorded, each a choice of two or a few: which episodes,
/// from which channel, at what time, and how many are kept; and the way to
/// stop recording it. A choice is the server's as soon as it's made: there's
/// nothing to save.
struct LiveSeriesPanel: View {
    @ObservedObject var model: LiveTVModel
    let id: String
    /// As it was when its row was chosen, until the list has it again.
    let first: LiveSeriesTimer
    let close: () -> Void

    private var series: LiveSeriesTimer { model.seriesTimers.first { $0.id == id } ?? first }

    var body: some View {
        let series = series
        let options = series.options
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: CGFloat(22).scaled) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Series")
                        .font(.app(13, .heavy))
                        .kerning(1.6)
                        .textCase(.uppercase)
                        .foregroundStyle(Theme.palette[2].1)
                    Text(series.name)
                        .font(.app(30, .bold))
                        .lineLimit(2)
                }
                group(String(localized: "Episodes")) {
                    pill(String(localized: "New Only", comment: "Series recording: only episodes that haven't been shown before"), options.newOnly) { $0.newOnly = true }
                    pill(String(localized: "All Episodes", comment: "Series recording: every showing, repeats too"), !options.newOnly) { $0.newOnly = false }
                }
                group(String(localized: "Channel", comment: "Series recording: which channel it's recorded from")) {
                    pill(series.ownChannel ?? String(localized: "This Channel", comment: "Series recording: only the channel it was set on"), !options.anyChannel) { $0.anyChannel = false }
                    pill(String(localized: "Any Channel", comment: "Series recording: whichever channel shows it"), options.anyChannel) { $0.anyChannel = true }
                }
                group(String(localized: "Time", comment: "Series recording: when showings are recorded")) {
                    pill(String(localized: "Around This Time", comment: "Series recording: only showings near the time it was set at"), !options.anyTime) { $0.anyTime = false }
                    pill(String(localized: "Any Time", comment: "Series recording: showings at any time of day"), options.anyTime) { $0.anyTime = true }
                }
                group(String(localized: "Keep", comment: "Series recording: how many recordings are kept")) {
                    pill(String(localized: "Everything", comment: "Series recording: every recording is kept"), options.keepUpTo == 0) { $0.keepUpTo = 0 }
                    // The server lets the oldest go as each new one begins.
                    ForEach(Self.keepCounts(with: options.keepUpTo), id: \.self) { count in
                        pill(count == 1 ? String(localized: "Only the Latest", comment: "Series recording: only the newest recording is kept")
                                        : String(localized: "The Latest \(count)", comment: "Series recording: only this many recordings are kept, the oldest going first"),
                             options.keepUpTo == count) { $0.keepUpTo = count }
                    }
                }
                HStack(spacing: 14) {
                    Button(String(localized: "Cancel Series Recording"), role: .destructive) {
                        model.cancel(.series(series), series: true)
                        close()
                    }
                    .buttonStyle(.pill(selected: false))
                    #if !os(tvOS)
                    Button("Done", action: close)
                        .buttonStyle(.pill(selected: false))
                    #endif
                }
                .padding(.top, 6)
            }
            .padding(CGFloat(40).scaled)
            .frame(maxWidth: CGFloat(1200).scaled, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .tvExitCommand(perform: close)
        // Said here: the page is under this.
        .alert(model.recordingProblem ?? "", isPresented: $model.recordingProblem.isPresent()) {}
    }

    /// How many recordings can be kept: a few, for the news, or more; and
    /// whatever it's set to already, if that's none of them (set elsewhere).
    static func keepCounts(with current: Int) -> [Int] {
        let offered = [1, 2, 3, 5, 10]
        return current > 0 && !offered.contains(current) ? (offered + [current]).sorted() : offered
    }

    private func group<Pills: View>(_ title: String, @ViewBuilder pills: () -> Pills) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.app(19, .semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) { pills() }
                    .padding(.vertical, 10)   // room for the focused pill's lift
                    .padding(.horizontal, 6)
            }
        }
        // Up and down between groups lands on the group, not the pill that happens to line up.
        .tvFocusSection()
    }

    private func pill(_ title: String, _ chosen: Bool, change: @escaping (inout LiveSeriesOptions) -> Void) -> some View {
        Button(title) {
            var options = series.options
            change(&options)
            model.set(options, for: series)
        }
        .buttonStyle(.pill(selected: chosen))
    }
}

/// A recording chosen from the list of them: one showing, or a series.
enum LiveScheduledAsked: Equatable {
    case timer(LiveTimer)
    case series(LiveSeriesTimer)

    /// Its row's name.
    var id: String {
        switch self {
        case .timer(let timer): "timer-" + timer.id
        case .series(let series): "series-" + series.id
        }
    }
}

/// Takes focus when it's told to by name: on a television, where something
/// has to have it. Kept to the control itself, so the telling redraws
/// nothing else.
private struct Summoned: ViewModifier {
    let id: String
    let summons: PassthroughSubject<String, Never>
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            .focused($focused)
            .onReceive(summons) { called in if called == id { focused = true } }
        #else
        content
        #endif
    }
}

/// Whether to call a recording off.
private struct LiveScheduledAsking: ViewModifier {
    let asked: LiveScheduledAsked?
    @Binding var isPresented: Bool
    let model: LiveTVModel
    /// Shows a recording that's under way from its beginning.
    var fromStart: ((LiveTimer) -> Void)? = nil

    private var title: String {
        switch asked {
        case .timer(let timer): timer.name
        case .series(let series): series.name
        case nil: ""
        }
    }

    func body(content: Content) -> some View {
        content.confirmationDialog(title, isPresented: $isPresented, titleVisibility: .visible, presenting: asked) { asked in
            switch asked {
            case .timer(let timer):
                if timer.isRecording, timer.channelId != nil, let fromStart {
                    Button(LiveTVModel.Recording.fromStartName) { fromStart(timer) }
                }
                Button(timer.isRecording ? String(localized: "Stop Recording") : String(localized: "Cancel Recording"), role: .destructive) {
                    model.cancel(asked, series: false)
                }
                if timer.seriesTimerId != nil {
                    Button(String(localized: "Cancel Series Recording"), role: .destructive) { model.cancel(asked, series: true) }
                }
            case .series:
                Button(String(localized: "Cancel Series Recording"), role: .destructive) { model.cancel(asked, series: true) }
            }
        } message: { asked in
            switch asked {
            case .timer(let timer):
                Text([LiveClock.day(timer.start), LiveClock.span(from: timer.start, to: timer.end), timer.channelName].compactMap { $0 }.joined(separator: " · "))
            case .series(let series):
                Text(series.channelName ?? "")
            }
        }
    }
}

/// One recording in the list of them: when, down the side, and what.
private struct ScheduledRow: View {
    /// The time it starts, or "Series" for a series.
    let when: String
    let day: String?
    let title: String
    let detail: String?
    /// Under way now.
    let recording: Bool
    /// One episode of a series that's set.
    let ofSeries: Bool
    let metrics: GuideMetrics
    /// What it answers to when it's told to take focus.
    let id: String
    let summons: PassthroughSubject<String, Never>
    let action: () -> Void

    var body: some View {
        let narrow = metrics.column < 150
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(when)
                    .font(.app(narrow ? 13 : 18, .semibold))
                    .monospacedDigit()
                if let day {
                    Text(day)
                        .font(.app(narrow ? 11 : 15))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, narrow ? 8 : 14)
            .frame(width: metrics.column - (narrow ? 6 : 0), height: metrics.rowHeight, alignment: .leading)
            .background(GuideMetrics.headFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(.leading, narrow ? 6 : 0)
            Button(action: action) {
                HStack(spacing: 12) {
                    LiveRecordingDot()
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title)
                            .font(.app(19, .semibold))
                            .lineLimit(1)
                        if let detail, !detail.isEmpty {
                            Text(detail)
                                .font(.app(14))
                                .opacity(0.7)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    if recording || ofSeries {
                        Text((recording ? String(localized: "Recording") : String(localized: "Series")).uppercased())
                            .font(.app(12, .heavy))
                            .kerning(1.2)
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            .buttonStyle(GuideCellStyle(onNow: recording, chosen: false))
            .modifier(Summoned(id: id, summons: summons))
            .frame(height: metrics.rowHeight)
        }
    }
}

/// How far the guide has been moved, for what stays put beside it to follow:
/// the times across the top, the channels down the side.
@MainActor
final class GuideScroll: ObservableObject {
    @Published var offset: CGPoint = .zero
}

/// Live TV: the guide, channels down the side and the hours across, with the
/// programme that's highlighted described over it and, in the corner, the
/// channel last tuned playing small. Select fills the screen with a
/// programme's channel, and that's the one in the corner from then on.
/// Where the guide is, for Back to ask as it's pressed, and Back's way of
/// sending it to its top: kept by whoever shows the page (the menu's screen
/// decides what Back does), and not watched by anything.
final class LiveGuidePlace {
    /// Whether the guide is away from its top: focus below the first
    /// channel, or the hours moved on from now.
    var isAway: () -> Bool = { false }
    /// Back was pressed with the guide away from its top.
    let returns = PassthroughSubject<Void, Never>()
}

struct LiveTVView: View {
    /// Nil where nothing steps Back through the page (a preview).
    var place: LiveGuidePlace? = nil
    @EnvironmentObject var app: AppState
    @Environment(\.isNarrow) private var narrow
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = LiveTVModel()
    @StateObject private var scroll = GuideScroll()
    @State private var watching = false
    /// How the sleep timer stops the channel playing in the corner.
    @State private var sleepToken: UUID?
    /// A programme that isn't on yet was chosen: what's to be done with it.
    @State private var asked: LiveAsked?
    /// A recording was chosen from the list of them.
    @State private var askedScheduled: LiveScheduledAsked?
    /// A series was chosen from that list: how it's recorded, to be changed.
    @State private var seriesOpen: LiveSeriesTimer?
    #if !os(tvOS)
    /// Where the guide is, to open it on the channel that's playing.
    @State private var position = ScrollPosition(edge: .top)
    #endif
    /// Whether focus has been in the guide yet. Until it has, the filters
    /// over it are out of reach, so that coming in from the menu lands on a
    /// programme and not on whatever stands first on the page.
    @State private var guideHadFocus = false
    #if os(tvOS)
    /// The programme focus is being sent to: what's on the channel the full
    /// screen was left on, or the one the guide opens on, or the first
    /// channel's when Back asks for the top.
    @State private var landing: String?
    /// The channel that programme is on, whose row is brought into view.
    @State private var destination: String?
    /// Coming back from the full screen, focus returns to where it left
    /// before it's moved to the channel that's playing: that first landing
    /// isn't the viewer choosing anything.
    @State private var returning = false
    /// The channel the full screen was opened on, to know on the way back
    /// whether it was changed there.
    @State private var entered: String?
    /// Bumped when the full screen has gone, which is when focus can be moved.
    @State private var settled = 0
    /// Whether the guide has been opened on the channel that's playing.
    @State private var opened = false
    #endif

    private var metrics: GuideMetrics { .make(narrow: narrow) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            LiveBand(model: model, highlight: model.highlight, tuner: model.tuner, watching: watching, compact: narrow,
                     logo: { app.client?.channelLogoURL($0, maxWidth: 320) }) {
                if let channel = model.highlight.playing { watch(channel) }
            }
            toolbar
                .padding(.horizontal, narrow ? Theme.pageMargin : 0)
                .padding(.top, narrow ? 10 : CGFloat(18).scaled)
                .padding(.bottom, narrow ? 6 : CGFloat(12).scaled)
            if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, minHeight: 240)
            } else if model.channels.isEmpty {
                Text("The server has no channels just now.", comment: "Live TV: the channel list came back empty")
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 40)
                    .padding(.horizontal, narrow ? Theme.pageMargin : 0)
            } else if model.filter == .scheduled {
                scheduled
            } else {
                guide
            }
        }
        .padding(.leading, narrow ? 0 : Theme.pageMargin)
        .padding(.top, narrow ? 0 : LiveBand.over)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Not under an iPhone Duo's camera strip (pageSides).
        .pageSides(!narrow, also: .bottom)
        .task { await follow() }
        .task { await keepTime() }
        #if os(tvOS)
        .onAppear {
            // The list of recordings has no top to go back to: Back opens
            // the menu from it.
            // The model isn't kept alive by being asked about: held here it
            // outlived the page, its tuner and player with it.
            place?.isAway = { [weak model, scroll, metrics] in
                guard let model, model.filter != .scheduled, let first = model.shown.first else { return false }
                // Anywhere but the programme Back would put focus on (see
                // `send`), or with the guide moved along from its start. By
                // the programme and not by the hour focus was last at: the
                // first channel's can be hours long and come to at any of
                // them, and with the hour to go by Back never found itself
                // at the top, and never opened the menu.
                let top = landingBlock(on: first)
                return model.focusedBlock != top || scroll.offset.y > 4 || scroll.offset.x > 4
            }
        }
        .onReceive(place?.returns ?? PassthroughSubject<Void, Never>()) { _ in
            if let first = model.shown.first { send(focusTo: first, now: true) }
        }
        .onReceive(model.lost) { id in
            // With the full screen up there's no focus here to keep: it's
            // seen to on the way back (see `leaveFullScreen`).
            guard !watching, let channel = model.shown.first(where: { $0.id == id }) else { return }
            app.holdMenuFocus()
            send(focusTo: channel, now: true)
        }
        #endif
        .onChange(of: model.filter) { _, filter in
            scroll.offset = .zero
            #if !os(tvOS)
            position = ScrollPosition(edge: .top)
            #endif
            if filter == .scheduled { Task { await model.loadTimers() } }
        }
        // The full screen is this page's own, over it: the channel plays on.
        .onDisappear { if !watching { model.tuner.stop() } }
        // A film asked for from another device opens over the guide: the
        // corner's channel isn't to be heard under it.
        .onReceive(NotificationCenter.default.publisher(for: RemoteControl.takingOver)) { _ in model.tuner.stop() }
        #if os(macOS) && DEBUG
        // A script's jellygoose://livewatch: the corner's channel full screen, as its button does.
        .onReceive(NotificationCenter.default.publisher(for: MacDebugSnapshots.watchLive)) { _ in
            if let channel = model.highlight.playing { watch(channel) }
        }
        #endif
        // Run out with the guide up: the corner's channel is let go too.
        .onAppear {
            let model = model
            sleepToken = SleepTimer.shared.register { [weak model] in model?.tuner.stop() }
        }
        .onDisappear { SleepTimer.shared.forget(sleepToken) }
        .onChange(of: scenePhase) { _, phase in
            // Put away, the app lets the tuner go; back, it takes the channel up again.
            if phase == .background {
                model.tuner.stop()
            } else if phase == .active, model.tuner.channelId == nil, !model.wallUp {
                // Or takes one up for the first time, where the app was put
                // away before the page had its channels (see `resume`).
                if let channel = model.highlight.playing { model.tune(channel) } else { model.resume() }
            }
        }
        #if os(tvOS)
        // In the middle of the screen, as a television asks. By touch it's
        // asked from the programme itself (see `cell`).
        .modifier(LiveAsking(asked: asked, isPresented: $asked.isPresent(), model: model, watch: watch,
                             fromStart: { watchFromStart($0.program, on: $0.channel) }))
        .modifier(LiveScheduledAsking(asked: askedScheduled, isPresented: $askedScheduled.isPresent(), model: model,
                                      fromStart: watchFromStart))
        #endif
        // Under the full screen it couldn't be shown: said there instead
        // (see `LiveWatchView`).
        .seriesPanel($seriesOpen, model: model)
        .alert(model.recordingProblem ?? "", isPresented: Binding(get: { !watching && seriesOpen == nil && model.recordingProblem != nil },
                                                                 set: { if !$0 { model.recordingProblem = nil } })) {}
        .fullScreenCover(isPresented: $watching, onDismiss: {
            #if os(tvOS)
            settled += 1
            #endif
        }) {
            LiveWatchView(model: model, tuner: model.tuner, highlight: model.highlight) { leaveFullScreen() }
        }
    }

    private func follow() async {
        guard let client = app.client else { return }
        // The channels as they were last chosen: all, the favourites, or a
        // kind of programme.
        model.restoreChoice()
        while !Task.isCancelled {
            // A server that couldn't be asked, with nothing to show
            // meanwhile, is asked again shortly: said to have no channels,
            // the page said so for five minutes.
            if await !model.load(from: client), model.channels.isEmpty {
                try? await Task.sleep(for: .seconds(15))
                continue
            }
            // The page opens on a picture: the channel last watched.
            model.resume()
            #if os(tvOS)
            openOnPlaying(from: model.cursorChannel)
            #endif
            #if !os(tvOS)
            // Nothing is highlighted by a finger that hasn't touched anything
            // yet: what's on the channel that's playing is, and the guide
            // opens with that channel a row from its top.
            if model.highlight.channel == nil, let first = model.highlight.playing ?? model.shown.first {
                model.look(at: first, program: model.current(on: first), settle: false)
                if let row = model.shown.firstIndex(where: { $0.id == first.id }), row > 1 {
                    // Across, to where the guide rests: its beginning clear
                    // of the channels' column, which the guide is inset by.
                    // Told only how far down, it went to nought across, and
                    // the first half-hour lay under the channels.
                    position.scrollTo(point: CGPoint(x: -(metrics.column + 10), y: metrics.edge + CGFloat(row - 1) * metrics.pitch))
                }
            }
            #endif
            try? await Task.sleep(for: .seconds(300))
        }
    }

    /// On the minute: the line that marks now moves, and what's on changes.
    private func keepTime() async {
        while !Task.isCancelled {
            let seconds = 60 - Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60)
            try? await Task.sleep(for: .seconds(seconds + 0.5))
            if !Task.isCancelled { model.tick() }
        }
    }

    #if os(tvOS)
    /// The guide opens on the channel that's playing. Focus comes in where
    /// the system puts it, the first channel as a rule, and is sent on, as
    /// it is on the way back from the full screen. Once, when focus is in
    /// the guide and the channel is known, whichever of the two comes
    /// second: opened from Home's row, the page had focus before it had
    /// heard which channel that was. True if focus is being sent on.
    @discardableResult
    private func openOnPlaying(from row: String?) -> Bool {
        guard !opened, guideHadFocus, let playing = model.highlight.playing else { return false }
        opened = true
        guard playing.id != row else { return false }
        return send(focusTo: playing, now: true)
    }

    /// The block drawn for what's on a channel: the one showing it, or the one
    /// it's folded into (a programme too short to draw goes into the block
    /// before it); the first, where nothing's on.
    private func landingBlock(on channel: LiveChannel) -> String? {
        let drawn = model.blocks(for: channel, in: metrics)
        let now = model.now
        return drawn.first { $0.program?.isOn(at: now) == true }?.id
            ?? drawn.last { ($0.program?.start ?? .distantFuture) <= now }?.id
            ?? drawn.first?.id
    }

    /// Sends focus to what's on a channel, its row brought into view from
    /// where the guide begins. `now`, when nothing else is about to say the
    /// moment for it (the full screen going does, as it goes).
    @discardableResult
    private func send(focusTo channel: LiveChannel, now: Bool) -> Bool {
        guard let target = landingBlock(on: channel) else { return false }
        landing = target
        destination = channel.id
        returning = true
        if now { settled += 1 }
        return true
    }
    #endif

    /// A programme was chosen. One that's on fills the screen. One that's to
    /// come can't be watched yet: where it can be recorded that's what's
    /// offered, with its channel as it is now.
    private func chose(_ block: GuideBlock, on channel: LiveChannel) {
        let listed = block.program.map { program in model.guide[channel.id]?.first { $0.id == program.id } ?? program }
        if let program = listed, !program.isOn(at: model.now), !model.recordings(for: program).isEmpty {
            // As the guide has it now, not as the row was last drawn.
            asked = LiveAsked(channel: channel, program: program)
        } else if let program = listed, program.isOn(at: model.now), program.timerId != nil,
                  model.now.timeIntervalSince(program.start) > 120 {
            // On, a while since, and being recorded: there's its beginning
            // to go to as well as where it's got to.
            asked = LiveAsked(channel: channel, program: program)
        } else {
            watch(channel)
        }
    }

    private func watch(_ channel: LiveChannel) {
        model.tune(channel)
        #if os(tvOS)
        entered = channel.id
        #endif
        watching = true
    }

    /// The full screen, on the programme's beginning as the server has
    /// recorded it.
    private func watchFromStart(_ program: LiveProgram, on channel: LiveChannel) {
        model.fromStart(program, on: channel)
        #if os(tvOS)
        entered = channel.id
        #endif
        watching = true
    }

    /// The same from the list of what's set to record, which knows the
    /// recording by its timer.
    private func watchFromStart(_ timer: LiveTimer) {
        guard let channel = model.channels.first(where: { $0.id == timer.channelId }) else { return }
        model.fromStart(timer: timer.id, on: channel)
        #if os(tvOS)
        entered = channel.id
        #endif
        watching = true
    }

    /// Back to the guide, on what's showing on the channel that's playing,
    /// which up and down may have changed since the guide was left.
    private func leaveFullScreen() {
        #if os(tvOS)
        // Left on the channel it was opened on, focus goes back to where it
        // was by itself.
        if let channel = model.highlight.playing, channel.id != entered {
            send(focusTo: channel, now: false)
        } else if let block = model.focusedBlock, let channel = model.shown.first(where: { $0.id == model.cursorChannel }),
                  !model.holds(block, on: channel) {
            // Or the programme it was opened from is over and gone from the
            // guide since: to what its channel has on now.
            send(focusTo: channel, now: false)
        }
        #endif
        watching = false
    }

    // MARK: Over the guide

    private var toolbar: some View {
        HStack(spacing: CGFloat(24).scaled) {
            if !narrow {
                // The page's name first, and not only to say where this is: a
                // control at the page's very edge sits outside the part of it
                // that focus moves about in, and couldn't be left downwards.
                VStack(alignment: .leading, spacing: 2) {
                    if model.loaded {
                        Text(Self.count(model.channels.count).uppercased())
                            .font(.app(12, .heavy))
                            .kerning(1.6)
                            .foregroundStyle(Theme.palette[2].1)
                    }
                    Text("Live TV", comment: "Menu section: the server's television channels")
                        .font(.app(24, .bold))
                }
                .frame(minWidth: metrics.column - CGFloat(24).scaled, alignment: .leading)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    Button(String(localized: "All Channels", comment: "Live TV filter: every channel")) { model.choose(.all) }
                        .buttonStyle(.chip(active: model.filter == .all))
                    if model.hasFavourites || model.filter == .favourites {
                        Button(String(localized: "Favourites")) { model.choose(.favourites) }
                            .buttonStyle(.chip(active: model.filter == .favourites))
                    }
                    ForEach(model.genres, id: \.self) { genre in
                        Button(Self.name(of: genre)) { model.choose(.genre(genre)) }
                            .buttonStyle(.chip(active: model.filter == .genre(genre)))
                    }
                    if model.canRecord {
                        Button(String(localized: "Scheduled", comment: "Live TV: shows the list of recordings that are set, in place of the guide")) { model.choose(.scheduled) }
                            .buttonStyle(.chip(active: model.filter == .scheduled))
                            .modifier(Summoned(id: LiveTVModel.scheduledChip, summons: model.summons))
                    }
                }
                .padding(.vertical, 8)   // room for the focused chip's lift
                .padding(.horizontal, 6)
            }
            .tvFocusSection()
            .disabled(!filtersReachable)
        }
    }

    private var filtersReachable: Bool {
        #if os(tvOS)
        guideHadFocus || (model.loaded && model.channels.isEmpty)
        #else
        true
        #endif
    }

    // MARK: What's set to record

    /// In the guide's place, and to its measures: when down the side where
    /// the channels were, and a row for each recording, the series first.
    /// Choosing one asks whether to call it off.
    private var scheduled: some View {
        let metrics = metrics
        return ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: metrics.rowGap) {
                if model.timersLoaded, model.timers.isEmpty, model.seriesTimers.isEmpty {
                    Text("Nothing is set to record.", comment: "Live TV: the list of scheduled recordings is empty")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 30)
                        .padding(.leading, narrow ? Theme.pageMargin : 0)
                }
                ForEach(model.seriesTimers) { series in
                    ScheduledRow(when: String(localized: "Series"), day: nil, title: series.name, detail: series.channelName,
                                 recording: false, ofSeries: false, metrics: metrics, id: LiveScheduledAsked.series(series).id,
                                 summons: model.summons) { seriesOpen = series }
                }
                ForEach(model.timers) { timer in
                    ScheduledRow(when: LiveClock.time(timer.start), day: LiveClock.day(timer.start),
                                 title: [timer.name, timer.episodeTitle.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " · "),
                                 detail: [timer.channelName, LiveClock.span(from: timer.start, to: timer.end)].compactMap { $0 }.joined(separator: " · "),
                                 recording: timer.isRecording, ofSeries: timer.seriesTimerId != nil, metrics: metrics,
                                 id: LiveScheduledAsked.timer(timer).id, summons: model.summons) { askedScheduled = .timer(timer) }
                        .modifier(asking(.timer(timer)))
                }
            }
            .padding(.vertical, metrics.edge)
            .padding(.trailing, Theme.pageMargin)
        }
        .tvFocusSection()
    }

    /// By touch, the question is asked from the row that was tapped; on a
    /// television, from the middle of the screen (see `body`).
    private func asking(_ row: LiveScheduledAsked) -> some ViewModifier {
        #if os(tvOS)
        EmptyModifier()
        #else
        LiveScheduledAsking(asked: askedScheduled, isPresented: Binding(
            get: { askedScheduled == row },
            set: { if !$0, askedScheduled == row { askedScheduled = nil } }), model: model, fromStart: watchFromStart)
        #endif
    }

    // MARK: The guide

    private var guide: some View {
        let metrics = metrics
        let channels = model.shown
        let total = metrics.width(of: LiveTVModel.span)
        return VStack(alignment: .leading, spacing: 0) {
            GuideTimes(scroll: scroll, start: model.guideStart, now: model.now, metrics: metrics)
            gated(metrics) {
                ScrollView([.horizontal, .vertical], showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: metrics.rowGap) {
                        ForEach(channels) { channel in
                            HStack(spacing: 0) {
                                ForEach(model.blocks(for: channel, in: metrics)) { block in
                                    cell(block, on: channel)
                                        .frame(width: block.width, height: metrics.rowHeight)
                                        .padding(.leading, block.lead)
                                        .padding(.trailing, metrics.gap)
                                }
                            }
                            .frame(width: total, height: metrics.rowHeight, alignment: .leading)
                        }
                    }
                    .padding(.vertical, metrics.edge)
                    // A row's room under the last channel on a phone. Sent to
                    // a channel near the end of the list, the guide stopped
                    // short of where a finger can take it, by about the
                    // height of the bar across the bottom, and the channel
                    // it was sent to lay half under that bar.
                    .padding(.bottom, narrow ? metrics.pitch : 0)
                    .padding(.trailing, Theme.pageMargin)
                    // The line that marks now, which moves with the guide.
                    // Behind the programmes, which are glass enough to show
                    // it: over them, it ran through the first letter of
                    // every title for a minute in each half-hour.
                    .background(alignment: .topLeading) {
                        Rectangle()
                            .fill(Theme.accent)
                            .frame(width: 2)
                            .offset(x: metrics.width(of: model.now.timeIntervalSince(model.guideStart)) - 1)
                    }
                }
                // A guide of its own for each filter, begun from the top and
                // from now. Kept, it stayed as far down as the last list had
                // been taken: narrowed to a few channels with a finger well
                // down all of them, it showed none.
                .id(model.filter)
                #if !os(tvOS)
                .scrollPosition($position)
                #endif
                // The channels stand over the guide's leading edge: the guide
                // keeps clear of them when it brings a programme into view.
                .safeAreaPadding(.leading, metrics.column + 10)
                .onScrollGeometryChange(for: CGPoint.self) { geometry in
                    CGPoint(x: geometry.contentOffset.x + geometry.contentInsets.leading,
                            y: geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, offset in
                    if offset != scroll.offset { scroll.offset = offset }
                }
                #if os(tvOS)
                .onChange(of: settled) { _, _ in
                    guard returning, let channel = channels.first(where: { $0.id == destination }),
                          let row = channels.firstIndex(where: { $0.id == channel.id }) else {
                        returning = false
                        return
                    }
                    Task {
                        // The programme is told to take focus as it stands:
                        // where its row is there to be focused, the guide
                        // brings it into view by itself, hours and all. With
                        // the guide moved first, a programme left with focus
                        // far along its row went out of sight still holding
                        // it, and focus wouldn't be taken from there.
                        app.holdMenuFocus()
                        model.forgetCursor()
                        if let landing { model.summons.send(landing) }
                        try? await Task.sleep(for: .milliseconds(300))
                        if let landing, model.focusedBlock == landing {
                            // Focus is on it. Without having moved, where it
                            // had it already (a programme hours long, come to
                            // from another row at a later hour): nothing
                            // landed, so nothing said where focus is, and
                            // Back went on asking for the top for good.
                            if model.cursorChannel == nil {
                                model.landed(on: channel, model.guide[channel.id]?.first { $0.id == landing }, block: landing)
                            }
                            // What's on now is where the guide begins: a long
                            // programme takes focus without the guide moving.
                            if scroll.offset.x > 4 { model.rowCalls.send(.show(row: row)) }
                        }
                        // A row a long way off isn't there to be told
                        // anything: brought to where the guide begins first,
                        // and more than once if it must be, since as the full
                        // screen goes focus is given back to the programme it
                        // was opened from and the guide goes back there with
                        // it, which may be after this.
                        // Where the programme lies along its row.
                        var across: CGFloat = 0
                        var edge: CGFloat = 0
                        for block in model.blocks(for: channel, in: metrics) {
                            if block.id == landing { across = edge + block.lead }
                            edge += block.lead + block.width + metrics.gap
                        }
                        for _ in 0..<3 where model.cursorChannel != channel.id {
                            // The programme focus is leaving goes out of
                            // sight as it does, and the menu would take focus
                            // for want of anywhere else: held off meanwhile.
                            app.holdMenuFocus()
                            model.rowCalls.send(.show(row: row))
                            try? await Task.sleep(for: .milliseconds(250))
                            model.forgetCursor()
                            // By the focus system itself, at the place the
                            // programme lies: asked to take focus the usual
                            // way, it wouldn't from a programme that had
                            // gone out of sight along its row holding it.
                            model.rowCalls.send(.focus(row: row, across: across + 12))
                            try? await Task.sleep(for: .milliseconds(350))
                        }
                        returning = false
                    }
                }
                #endif
            }
            // Programmes going by under the channels aren't drawn there:
            // cut away, not covered, so the wallpaper is what shows.
            .mask {
                HStack(spacing: 0) {
                    Color.clear.frame(width: metrics.column + 4)
                    Rectangle()
                }
            }
            .overlay(alignment: .topLeading) {
                GuideChannels(scroll: scroll, channels: channels, metrics: metrics,
                              logo: { app.client?.channelLogoURL($0, maxWidth: 160) })
            }
            .clipped()
            .tvFocusSection()
        }
    }

    /// On a television, the guide's rows are in a host of their own, which
    /// is asked before focus goes up or down between them (see `GuideGate`).
    @ViewBuilder
    private func gated<Rows: View>(_ metrics: GuideMetrics, @ViewBuilder rows: () -> Rows) -> some View {
        #if os(tvOS)
        GuideGate(rows: rows(), rowCalls: model.rowCalls, metrics: metrics) { from, to in mayMove(from: from, to: to, in: metrics) }
        #else
        rows()
        #endif
    }

    #if os(tvOS)
    /// Whether focus may go from one programme to another in a different
    /// row, each given by where it lies in the guide. Left to itself, focus
    /// goes to whatever lies under the middle of the programme it's leaving:
    /// from a film three hours long, or a channel with no listings, whose
    /// one block is the width of the guide, that's a programme hours from
    /// the one the viewer was looking at, and the guide swung round to show
    /// it. So it's sent to the one on at the viewer's time instead.
    private func mayMove(from: CGRect?, to: CGRect, in metrics: GuideMetrics) -> Bool {
        guard let from else {
            model.forgetCursor()
            return true
        }
        guard abs(to.midY - from.midY) > metrics.rowHeight / 2 else { return true }
        let channels = model.shown
        let row = Int(((to.midY - metrics.edge) / metrics.pitch).rounded(.down))
        guard channels.indices.contains(row), let wanted = model.cursorBlock(for: channels[row], in: metrics) else { return true }
        // It's the one focus was going to anyway.
        if abs(to.minX - wanted.span.lowerBound) < 3 { return true }
        // Refused a moment ago for this same programme, and here's the
        // press again: it didn't take focus when told to. Better the wrong
        // programme in the right row than a remote that does nothing.
        let moment = Date()
        if let last = model.refusal, last.id == wanted.id, (0.4...4).contains(moment.timeIntervalSince(last.at)) {
            model.refusal = nil
            return true
        }
        if model.refusal?.id != wanted.id || moment.timeIntervalSince(model.refusal?.at ?? .distantPast) > 4 {
            model.refusal = (wanted.id, moment)
        }
        model.summons.send(wanted.id)
        return false
    }
    #endif

    private func cell(_ block: GuideBlock, on channel: LiveChannel) -> some View {
        #if os(tvOS)
        GuideCell(block: block, onNow: block.program?.isOn(at: model.now) ?? true, chosen: false,
                  ownShow: block.program.map(channel.isNamed) ?? false,
                  favourite: channel.isFavorite, summons: model.summons,
                  landed: {
                      if !guideHadFocus {
                          guideHadFocus = true
                          if openOnPlaying(from: channel.id) { return }
                      }
                      if returning, block.id != landing { return }
                      model.landed(on: channel, block.program, block: block.id)
                      model.look(at: channel, program: block.program)
                  },
                  left: { model.left(block: block.id) },
                  toggleFavourite: { model.toggleFavourite(channel) }, recordings: recordings(for: block)) { chose(block, on: channel) }
        #else
        GuideChosen(highlight: model.highlight, channel: channel.id, program: block.program?.id) { chosen in
            GuideCell(block: block, onNow: block.program?.isOn(at: model.now) ?? true, chosen: chosen,
                      ownShow: block.program.map(channel.isNamed) ?? false,
                      favourite: channel.isFavorite, summons: model.summons, landed: {},
                      toggleFavourite: { model.toggleFavourite(channel) }, recordings: recordings(for: block)) {
                // A first tap brings the programme to the top of the page; a
                // tap on the one that's there fills the screen with its
                // channel, or asks what's to be done with one that's to come.
                if chosen { chose(block, on: channel) }
                else { model.look(at: channel, program: block.program, settle: false) }
            }
        }
        // Asked from the programme that was tapped, which is where the
        // question points: asked from the page, it pointed at whatever
        // lay in the middle of it.
        .modifier(LiveAsking(asked: asked, isPresented: Binding(
            get: { asked?.program.id == block.id && asked?.channel.id == channel.id },
            set: { if !$0, asked?.program.id == block.id { asked = nil } }), model: model, watch: watch,
            fromStart: { watchFromStart($0.program, on: $0.channel) }))
        #endif
    }

    /// What a programme's own menu offers about recording it.
    private func recordings(for block: GuideBlock) -> [GuideCell.Choice] {
        guard let program = block.program else { return [] }
        return model.recordings(for: program).map { choice in
            GuideCell.Choice(name: model.name(of: choice, for: program), undoes: choice.undoes, plays: choice == .fromStart) {
                if choice == .fromStart, let channel = model.channels.first(where: { $0.id == program.channelId }) {
                    watchFromStart(program, on: channel)
                } else {
                    model.set(choice, for: program)
                }
            }
        }
    }

    static func count(_ channels: Int) -> String {
        channels == 1 ? String(localized: "1 channel", comment: "Live TV: how many channels the server has")
                      : String(localized: "\(channels) channels", comment: "Live TV: how many channels the server has")
    }

    static func name(of genre: LiveGenre) -> String {
        switch genre {
        case .news: String(localized: "News", comment: "Live TV filter: channels showing news now")
        case .sports: String(localized: "Sport", comment: "Live TV filter: channels showing sport now")
        case .movies: String(localized: "Films", comment: "Live TV filter: channels showing a film now")
        case .kids: String(localized: "Kids", comment: "Live TV filter: channels showing children's programmes now")
        }
    }
}

// MARK: - The guide's parts

#if os(tvOS)
/// The guide's rows in a host of their own, to be asked about focus. Between
/// two of SwiftUI's own controls focus goes where the system sends it, and
/// SwiftUI has no say; a view controller over them has, before the move is
/// made, and may refuse it. This one asks, of every move that ends in the
/// guide, where the two programmes lie, and the guide answers.
private struct GuideGate<Rows: View>: UIViewControllerRepresentable {
    let rows: Rows
    /// What the guide's scroll view is told to do.
    let rowCalls: PassthroughSubject<LiveTVModel.GuideCall, Never>
    let metrics: GuideMetrics
    /// From where (nil for outside the guide) to where, as rectangles in
    /// the guide: points across from where it begins, and down from its
    /// first channel.
    let allow: (CGRect?, CGRect) -> Bool

    func makeUIViewController(context: Context) -> Host {
        let host = Host(rootView: rows)
        host.view.backgroundColor = .clear
        host.allow = allow
        host.metrics = metrics
        host.calls = rowCalls.sink { [weak host] call in
            switch call {
            case .show(let row): host?.show(row: row)
            case .focus(let row, let across): host?.focus(row: row, across: across)
            }
        }
        return host
    }

    func updateUIViewController(_ host: Host, context: Context) {
        host.rootView = rows
        host.allow = allow
        host.metrics = metrics
    }

    final class Host: UIHostingController<Rows> {
        var allow: ((CGRect?, CGRect) -> Bool)?
        var metrics: GuideMetrics?
        var calls: AnyCancellable?
        private weak var found: UIScrollView?
        /// The programme focus is being sent to, for the moment of sending.
        private var wanted: (any UIFocusItem)?

        override var preferredFocusEnvironments: [any UIFocusEnvironment] {
            wanted.map { [$0] } ?? super.preferredFocusEnvironments
        }

        /// Brings a channel's row to the middle of the guide, from where the
        /// guide begins. Done here, by the measures, since the row may be a
        /// long way off and not yet made: nothing of SwiftUI's can be told
        /// to scroll to what isn't there.
        func show(row: Int) {
            guard let scroller, let metrics else { return }
            let inset = scroller.adjustedContentInset
            let middle = metrics.edge + CGFloat(row) * metrics.pitch + metrics.rowHeight / 2
            let furthest = scroller.contentSize.height + inset.bottom - scroller.bounds.height
            let top = max(min(middle - scroller.bounds.height / 2, furthest), -inset.top)
            scroller.setContentOffset(CGPoint(x: -inset.left, y: top), animated: false)
        }

        /// The guide's scroll view: its coordinates are the guide's.
        private var scroller: UIScrollView? {
            if let found { return found }
            var queue: [UIView] = [view]
            while !queue.isEmpty {
                let next = queue.removeFirst()
                if let scroll = next as? UIScrollView {
                    found = scroll
                    return scroll
                }
                queue.append(contentsOf: next.subviews)
            }
            return nil
        }

        /// Puts focus on the programme lying at a place in the guide, which
        /// has to be in view: the focus system is asked for it outright.
        func focus(row: Int, across: CGFloat) {
            guard let scroller, let metrics else { return }
            let spot = CGPoint(x: across, y: metrics.edge + CGFloat(row) * metrics.pitch + metrics.rowHeight / 2)
            // Down through whatever holds the guide's controls to the one
            // lying there: they aren't views of the scroll view's own.
            var holders: [any UIFocusItemContainer] = [scroller]
            var looked = 0
            while let holder = holders.popLast(), looked < 300 {
                looked += 1
                let there = holder.coordinateSpace.convert(spot, from: scroller)
                for item in holder.focusItems(in: CGRect(x: there.x - 1, y: there.y - 1, width: 2, height: 2)) {
                    if item.canBecomeFocused {
                        // Asked of this controller, which focus is inside,
                        // and answered by it (`preferredFocusEnvironments`):
                        // the system only takes a request from somewhere
                        // that has focus in it already.
                        wanted = item
                        setNeedsFocusUpdate()
                        updateFocusIfNeeded()
                        wanted = nil
                        return
                    }
                    if let inner = item.focusItemContainer, inner !== holder { holders.append(inner) }
                }
            }
        }

        private func place(of item: any UIFocusItem, in scroller: UIScrollView) -> CGRect? {
            var inside = false
            var around: (any UIFocusEnvironment)? = item
            while let here = around, !inside {
                inside = here === scroller
                around = here.parentFocusEnvironment
            }
            guard inside, let space = item.parentFocusEnvironment?.focusItemContainer?.coordinateSpace else { return nil }
            return space.convert(item.frame, to: scroller)
        }

        override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
            guard super.shouldUpdateFocus(in: context) else { return false }
            guard let allow, let scroller, let next = context.nextFocusedItem, let to = place(of: next, in: scroller) else { return true }
            let from = context.previouslyFocusedItem.flatMap { place(of: $0, in: scroller) }
            // Sideways it goes where the system sends it; told to go
            // somewhere (no heading at all), where it was told.
            guard from == nil || context.focusHeading.contains(.up) || context.focusHeading.contains(.down) else { return true }
            return allow(from, to)
        }
    }
}
#endif

/// The hours across the top, which move with the guide.
private struct GuideTimes: View {
    @ObservedObject var scroll: GuideScroll
    let start: Date
    let now: Date
    let metrics: GuideMetrics

    var body: some View {
        let slot = metrics.width(of: 1800)
        let nowAt = metrics.width(of: now.timeIntervalSince(start))
        // The room the time now takes, which a half-hour under it gives up.
        let nowWide: CGFloat = metrics.column < 150 ? 70 : CGFloat(96).scaled
        // Laid over a strip the width of the page, and not in it: the hours
        // run to several screens' width, and as part of the page they made
        // the page that wide.
        Color.clear
            .frame(height: CGFloat(30).scaled)
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    HStack(spacing: 0) {
                        ForEach(0..<Int(LiveTVModel.span / 1800), id: \.self) { half in
                            Text(LiveClock.time(start.addingTimeInterval(Double(half) * 1800)))
                                .font(.app(15, .semibold))
                                .foregroundStyle(.white.opacity(0.75))
                                .lineLimit(1)
                                .frame(width: slot, alignment: .leading)
                                .opacity((nowAt - nowWide...nowAt + nowWide).contains(CGFloat(half) * slot) ? 0 : 1)
                        }
                    }
                    Text(LiveClock.time(now))
                        .font(.app(13, .heavy))
                        .foregroundStyle(Color(white: 0.06))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Theme.accent, in: Capsule())
                        .fixedSize()
                        .offset(x: nowAt + 6)
                }
                .fixedSize()
                .offset(x: metrics.column + 10 - scroll.offset.x)
            }
            // The hours pass out of sight under the channels' column, as
            // the programmes do.
            .mask {
                HStack(spacing: 0) {
                    Color.clear.frame(width: metrics.column + 4)
                    Rectangle()
                }
            }
            .accessibilityHidden(true)
    }
}

/// The channels down the side: over the guide's edge, and moving up and down
/// with it.
private struct GuideChannels: View {
    @ObservedObject var scroll: GuideScroll
    let channels: [LiveChannel]
    let metrics: GuideMetrics
    let logo: (LiveChannel) -> URL?

    var body: some View {
        let narrow = metrics.column < 150
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            ForEach(channels) { channel in
                Group {
                    if narrow {
                        // A phone: the number over the name.
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 4) {
                                Text(channel.number ?? "")
                                    .font(.app(11))
                                    .monospacedDigit()
                                    .foregroundStyle(.white.opacity(0.75))
                                if channel.isFavorite { star }
                            }
                            Text(channel.name)
                                .font(.app(12, .semibold))
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                        }
                        .padding(.horizontal, 8)
                    } else {
                        // The station's mark first, as big as the row lets
                        // it be, with the number over the name beside it:
                        // in a line with them it was a third the size. A
                        // channel without one keeps the place, so the
                        // words begin in a line down the column.
                        HStack(spacing: 8) {
                            Group {
                                if let url = logo(channel) {
                                    RemoteImage(url: url, contentMode: .fit)
                                } else {
                                    Image(systemName: "tv")
                                        .font(.app(22))
                                        .foregroundStyle(.white.opacity(0.35))
                                        .accessibilityHidden(true)
                                }
                            }
                            .frame(width: CGFloat(66).scaled, height: CGFloat(46).scaled)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 5) {
                                    Text(channel.number ?? "")
                                        .font(.app(12))
                                        .monospacedDigit()
                                        .foregroundStyle(.white.opacity(0.75))
                                    if channel.isFavorite { star }
                                }
                                Text(channel.name)
                                    .font(.app(14, .semibold))
                                    .minimumScaleFactor(0.7)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                .frame(width: metrics.column - (narrow ? 6 : 0), height: metrics.rowHeight, alignment: .leading)
                .background(GuideMetrics.headFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(.leading, narrow ? 6 : 0)
            }
        }
        .padding(.top, metrics.edge)
        .offset(y: -scroll.offset.y)
        .frame(width: metrics.column + 10, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        .allowsHitTesting(false)
    }

    private var star: some View {
        Image(systemName: "star.fill")
            .font(.app(11))
            .foregroundStyle(.white.opacity(0.6))
            .accessibilityLabel(Text("Favourite", comment: "Read out for a channel marked as a favourite"))
    }
}

#if !os(tvOS)
/// Which programme is the one at the top of the page. A finger leaves no
/// highlight behind as focus does, so the block says so itself; kept to the
/// blocks, so that the page around them isn't redrawn with each change.
private struct GuideChosen<Cell: View>: View {
    @ObservedObject var highlight: LiveHighlight
    let channel: String
    let program: String?
    @ViewBuilder let cell: (Bool) -> Cell

    var body: some View { cell(highlight.channel?.id == channel && highlight.program?.id == program) }
}
#endif

/// One programme in the guide.
private struct GuideCell: View {
    let block: GuideBlock
    let onNow: Bool
    /// The one described at the top of the page, where nothing else shows which.
    let chosen: Bool
    /// The channel is named for the programme (see `LiveChannel.isNamed`):
    /// an episode goes by its own name here, not the show's again.
    var ownShow = false
    let favourite: Bool
    /// Where a programme is told to take focus: the one on the channel the
    /// full screen was left on, or the one in the viewer's column of the
    /// guide. Listened to, not drawn from, so the telling redraws nothing.
    let summons: PassthroughSubject<String, Never>
    /// Focus came to it.
    let landed: () -> Void
    /// Focus left it.
    var left: () -> Void = {}
    let toggleFavourite: () -> Void
    /// What its menu offers about recording it, in order.
    let recordings: [Choice]
    let action: () -> Void
    @FocusState private var focused: Bool

    struct Choice {
        let name: String
        /// Takes a recording off, where the others set one.
        let undoes: Bool
        /// Shows something, where the others set the server to record or not.
        var plays = false
        let action: () -> Void
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                if let program = block.program {
                    // An episode with a name of its own says so: after the
                    // time it starts, or, on a channel that shows the one
                    // thing all day and is named for it, in the show's
                    // place, where it's all that tells one from the next.
                    let episode = program.episodeTitle.flatMap { $0.isEmpty || $0 == program.name ? nil : $0 }
                    HStack(spacing: 7) {
                        if program.isSetToRecord { LiveRecordingDot(says: program.recordingNote(onNow: onNow)) }
                        Text(ownShow ? episode ?? program.name : program.name)
                            .font(.app(19, .semibold))
                            .lineLimit(1)
                    }
                    HStack(spacing: 0) {
                        Text(LiveClock.time(program.start))
                            .opacity(0.7)
                            .fixedSize()
                        if !ownShow, let episode {
                            Text(verbatim: " · " + episode)
                                .opacity(0.92)
                        }
                    }
                    .font(.app(14))
                    .lineLimit(1)
                } else {
                    Text("No guide for this channel.", comment: "Live TV: the server has no programme listings for the channel")
                        .font(.app(17))
                        .opacity(0.7)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, block.width < 70 ? 6 : 16)
            // A long programme part-way off the guide's leading edge keeps
            // its name where it can be read, up against the edge. Worked out
            // as the guide is drawn, so nothing is redrawn for it.
            .visualEffect { [width = block.width] content, geometry in
                // Measured from where the guide's programmes come into
                // sight, past the channels' column.
                let hidden = -geometry.frame(in: .scrollView(axis: .horizontal)).minX
                return content.offset(x: min(max(hidden, 0), max(width - 90, 0)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .buttonStyle(GuideCellStyle(onNow: onNow, chosen: chosen))
        .focused($focused)
        .onChange(of: focused) { _, has in if has { landed() } else { left() } }
        .onReceive(summons) { id in if id == block.id { focused = true } }
        .contextMenu {
            ForEach(Array(recordings.enumerated()), id: \.offset) { _, choice in
                Button(choice.name, systemImage: choice.plays ? "backward.end" : choice.undoes ? "xmark.circle" : "record.circle",
                       role: choice.undoes ? .destructive : nil, action: choice.action)
            }
            Button(favourite ? String(localized: "Remove from Favourites") : String(localized: "Add to Favourites"),
                   systemImage: favourite ? "star.slash" : "star", action: toggleFavourite)
        }
    }
}

/// White when it has focus, as every control in the app is, and nothing that
/// moves: the highlight is all that travels about the guide. What's on now
/// stands a little brighter than what's to come.
private struct GuideCellStyle: ButtonStyle {
    let onNow: Bool
    let chosen: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .foregroundStyle(focused ? Color(white: 0.06) : .white)
            .background(focused ? Color.white : Color.white.opacity(configuration.isPressed || chosen ? 0.2 : (onNow ? 0.13 : 0.06)), in: shape)
            .overlay { if chosen, !focused { shape.strokeBorder(Theme.accent.opacity(0.9), lineWidth: 2) } }
            .clipShape(shape)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}

/// How far through a programme is.
struct LiveProgressLine: View {
    let fraction: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.gray.opacity(0.35))
                Capsule().fill(Theme.gradient(Theme.primary, start: .leading, end: .trailing))
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: height)
    }
}

enum LiveClock {
    static func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// "7:45 – 9:45 PM", as the device writes a stretch of time. One that
    /// runs past midnight is written as its two times: the device's way
    /// with that is to give both dates in full.
    static func span(_ program: LiveProgram) -> String { span(from: program.start, to: program.end) }

    static func span(from start: Date, to end: Date) -> String {
        guard Calendar.current.isDate(start, inSameDayAs: end) else {
            return "\(time(start)) – \(time(end))"
        }
        return (start..<end).formatted(.interval.hour().minute())
    }

    private static let nearDay: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// "Today", "Tomorrow" as the device says them, then "Sun 11".
    static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) { return nearDay.string(from: date) }
        return date.formatted(.dateTime.weekday(.abbreviated).day())
    }

    /// "1h 33m left".
    static func left(_ program: LiveProgram, at moment: Date = Date()) -> String {
        let minutes = max((program.end.timeIntervalSince(moment) / 60).rounded(.up), 1)
        let amount = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return String(localized: "\(amount) left", comment: "How much of a television programme is still to run; the placeholder is a length of time like 1h 33m")
    }
}

/// The red of a recording.
private let recordingRed = Color(red: 0.94, green: 0.2, blue: 0.2)

/// The red dot of a programme the server is recording, or is set to.
/// Read out as what it's given to say, where the words aren't beside it.
struct LiveRecordingDot: View {
    var size: CGFloat = 9
    var says: String?

    var body: some View {
        Circle()
            .fill(recordingRed)
            .frame(width: size, height: size)
            .accessibilityLabel(Text(says ?? ""))
            .accessibilityHidden(says == nil)
    }
}

extension LiveProgram {
    /// What's said of its recording at the top of the page, if there's one.
    func recordingNote(at moment: Date) -> String? { recordingNote(onNow: isOn(at: moment)) }

    func recordingNote(onNow: Bool) -> String? {
        guard isSetToRecord else { return nil }
        let what = onNow && timerId != nil
            ? String(localized: "Recording", comment: "Live TV: the server is recording this programme now")
            : String(localized: "Will Record", comment: "Live TV: the server is set to record this programme when it comes on")
        return seriesTimerId == nil ? what : [what, String(localized: "Series")].joined(separator: " · ")
    }
}

extension LiveTVModel.Recording {
    /// Takes a recording off, where the others set one.
    var undoes: Bool { self == .cancel || self == .cancelSeries }

    /// What can be done about recording a programme, in the order it's
    /// offered: nothing, for one that's over. The same wherever a programme
    /// is met: in the guide, full screen, and on Home's row of what's on.
    static func choices(for program: LiveProgram, at now: Date) -> [Self] {
        guard program.end > now else { return [] }
        var choices: [Self] = []
        // Being recorded as it's on: what there is of it can be watched.
        if program.timerId != nil, program.isOn(at: now) { choices.append(.fromStart) }
        choices.append(program.timerId == nil ? .record : .cancel)
        if program.seriesTimerId != nil { choices.append(.cancelSeries) }
        else if program.comesRound { choices.append(.recordSeries) }
        return choices
    }

    static var fromStartName: String {
        String(localized: "Watch from the Start", comment: "Live TV: shows a programme that's being recorded as it's broadcast from its beginning, while the recording goes on")
    }

    func name(for program: LiveProgram, at now: Date) -> String {
        switch self {
        case .fromStart: Self.fromStartName
        case .record: String(localized: "Record", comment: "Live TV: sets the server to record this programme")
        case .recordSeries: String(localized: "Record Series", comment: "Live TV: sets the server to record every episode of this series")
        case .cancel:
            program.isOn(at: now) ? String(localized: "Stop Recording", comment: "Live TV: stops a recording that's under way")
                                  : String(localized: "Cancel Recording", comment: "Live TV: takes off a recording that's set for later")
        case .cancelSeries: String(localized: "Cancel Series Recording", comment: "Live TV: stops recording every episode of this series")
        }
    }

    /// Asks the server for it.
    func send(for program: LiveProgram, to client: any MediaServer) async throws {
        switch self {
        // Not the server's to do: the picture goes back (see `LiveTVModel.fromStart`).
        case .fromStart: break
        case .record: try await client.liveRecord(programId: program.id, series: false)
        case .recordSeries: try await client.liveRecord(programId: program.id, series: true)
        case .cancel: if let id = program.timerId { try await client.liveCancelRecording(timerId: id) }
        case .cancelSeries: if let id = program.seriesTimerId { try await client.liveCancelSeries(timerId: id) }
        }
    }

    /// What's said when the server wouldn't.
    var failure: String {
        undoes ? String(localized: "Couldn't cancel the recording.", comment: "Live TV: the server refused or didn't answer when asked to cancel a recording")
               : String(localized: "Couldn't set the recording.", comment: "Live TV: the server refused or didn't answer when asked to record a programme")
    }
}

/// The channels with what's on each, to choose among over the picture
/// that's playing: the mini guide by touch. Opens on the channel that's on.
struct LiveChannelList: View {
    @ObservedObject var model: LiveTVModel
    let playing: String
    let logo: (LiveChannel) -> URL?
    let choose: (LiveChannel) -> Void

    private var channels: [LiveChannel] {
        model.shown.contains { $0.id == playing } ? model.shown : model.channels
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(channels) { channel in
                        Button { choose(channel) } label: { row(channel) }
                            .buttonStyle(.plain)
                            .id(channel.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 18)
            }
            .onAppear { proxy.scrollTo(playing, anchor: .center) }
        }
    }

    private func row(_ channel: LiveChannel) -> some View {
        let program = model.current(on: channel)
        let on = channel.id == playing
        return HStack(spacing: 14) {
            ZStack {
                if let url = logo(channel) {
                    RemoteImage(url: url, contentMode: .fit)
                } else {
                    Image(systemName: "tv").foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 58, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text([channel.number, channel.name].compactMap { $0 }.joined(separator: " · ").uppercased())
                        .font(.app(12, .heavy))
                        .kerning(1)
                        .foregroundStyle(Theme.palette[2].1)
                        .lineLimit(1)
                    if on { LiveBadge().scaleEffect(0.8, anchor: .leading) }
                    if program?.isSetToRecord == true { LiveRecordingDot(size: 8) }
                }
                Text(program?.name ?? channel.name)
                    .font(.app(17, .semibold))
                    .lineLimit(1)
                if let program {
                    Text([LiveClock.left(program, at: model.now), model.next(on: channel).map { String(localized: "Next: \($0.name)", comment: "Live TV banner: the programme that follows; the placeholder is its title") }]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.app(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(on ? AnyShapeStyle(Theme.gradient(Theme.primary).opacity(0.34)) : AnyShapeStyle(Color.white.opacity(0.07)),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// The small pill that says the picture is what's on the air now.
struct LiveBadge: View {
    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(Color(red: 1, green: 0.42, blue: 0.29)).frame(width: 8, height: 8)
            Text("LIVE", comment: "Badge on a television picture that's on the air now, in capitals")
                .font(.app(13, .heavy))
                .kerning(1.2)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(.black.opacity(0.7), in: Capsule())
    }
}

extension LiveTuner.Phase {
    /// What's said in place of the picture, when there's to be none.
    var trouble: String? {
        switch self {
        case .refused:
            String(localized: "Couldn't get this channel. Every tuner may be in use.",
                   comment: "Live TV: the server had no stream to give for the channel")
        case .lost:
            String(localized: "The channel stopped coming. Choose it again to retry.",
                   comment: "Live TV: the channel's stream broke off or never showed a picture")
        case .unplayable:
            String(localized: "This channel's sound is in a format that can't be played yet (AC-4).",
                   comment: "Live TV: a newer kind of broadcast (ATSC 3.0) whose audio the app has no decoder for. AC-4 is the format's name")
        case .unanswered:
            String(localized: "The server didn't answer for this channel. Choose it again to retry.",
                   comment: "Live TV: the server never replied when asked to tune the channel")
        case .idle, .tuning, .playing:
            nil
        }
    }
}

// MARK: - The highlighted programme

/// Over the guide: what the highlighted programme is, and beside it the
/// channel that's playing, which is the one last tuned and says which.
private struct LiveBand: View {
    @ObservedObject var model: LiveTVModel
    @ObservedObject var highlight: LiveHighlight
    @ObservedObject var tuner: LiveTuner
    let watching: Bool
    let compact: Bool
    let logo: (LiveChannel) -> URL?
    let watch: () -> Void

    // On a television the band begins at the top of what's safe to draw in
    // and the picture is as tall as the band: the corner over it stood
    // empty. A tablet held upright hasn't the width for a bigger one.
    #if os(tvOS)
    static let over: CGFloat = 0
    static let height = CGFloat(290).scaled
    static let pictureWidth = height * 16 / 9
    #else
    static let over = CGFloat(36).scaled
    static let height = CGFloat(240).scaled
    static let pictureWidth = CGFloat(420).scaled
    #endif

    var body: some View {
        if compact {
            // A phone: the picture across the top, a line or two under it.
            VStack(alignment: .leading, spacing: 0) {
                preview
                if let channel = highlight.channel { brief(channel) }
            }
        } else {
            HStack(alignment: .center, spacing: CGFloat(40).scaled) {
                Group {
                    if let channel = highlight.channel { details(channel) } else { Color.clear }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                preview
                    .frame(width: Self.pictureWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(.trailing, Theme.pageMargin)
            .frame(height: Self.height)
        }
    }

    private var preview: some View {
        let channel = highlight.playing
        return ZStack {
            Theme.surface
            if let channel { waiting(channel) }
            LiveSurface(tuner: tuner, showing: !watching)
                .opacity(tuner.shows(channel?.id) ? 1 : 0)
                // The player's own view takes a finger for itself: with the
                // picture showing, a tap on it never reached the page.
                .allowsHitTesting(false)
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .overlay(alignment: .topLeading) {
            if tuner.shows(channel?.id) { LiveBadge().padding(12) }
        }
        // Which channel the picture is: not the highlighted programme's,
        // unless that's the one that was last tuned.
        .overlay(alignment: .bottomLeading) {
            if let channel, tuner.shows(channel.id) {
                Text(name(of: channel))
                    .font(.app(13, .heavy))
                    .kerning(0.6)
                    .lineLimit(1)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(.black.opacity(0.7), in: Capsule())
                    .padding(12)
            }
        }
        #if !os(tvOS)
        .overlay(alignment: .bottomTrailing) {
            if tuner.shows(channel?.id) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 13, weight: .bold))
                    .padding(8)
                    .background(.black.opacity(0.6), in: Circle())
                    .padding(10)
                    .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: watch)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(Text("Fills the screen with this channel"))
        #endif
    }

    /// Under the picture until it's there, and in its place when it can't be.
    private func waiting(_ channel: LiveChannel) -> some View {
        VStack(spacing: 10) {
            if let url = logo(channel) {
                RemoteImage(url: url, contentMode: .fit)
                    .frame(width: CGFloat(150).scaled, height: CGFloat(80).scaled)
            } else {
                Text(channel.name)
                    .font(.app(22, .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            if let trouble = (tuner.channelId == channel.id ? tuner.phase : .tuning).trouble {
                Text(trouble)
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            } else {
                ProgressView()
            }
        }
        .padding(16)
    }

    private func name(of channel: LiveChannel) -> String {
        [channel.number, channel.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func details(_ channel: LiveChannel) -> some View {
        let program = highlight.program
        let onNow = program?.isOn(at: model.now) ?? false
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                if onNow { LiveBadge() }
                Text(name(of: channel).uppercased())
                    .font(.app(14, .heavy))
                    .kerning(1.6)
                    .foregroundStyle(Theme.palette[2].1)
                    .lineLimit(1)
                if let note = program?.recordingNote(at: model.now) {
                    HStack(spacing: 7) {
                        LiveRecordingDot(size: 10)
                        Text(note.uppercased())
                            .font(.app(14, .heavy))
                            .kerning(1.2)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            Text(program?.name ?? channel.name)
                .font(.app(40, .bold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let program {
                // One line of words, and the bar under it: side by side they
                // wanted more room than a tablet held upright has beside the
                // picture.
                Text([LiveClock.span(program), onNow ? LiveClock.left(program, at: model.now) : nil,
                      program.episodeTitle.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: " · "))
                    .font(.app(20))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if onNow {
                    LiveProgressLine(fraction: program.fraction(at: model.now), height: 5)
                        .frame(maxWidth: CGFloat(420).scaled)
                }
                LiveProgrammeAbout(program: program, font: .app(18), color: Theme.textSecondary, lines: 2)
            } else {
                Text("No guide for this channel.", comment: "Live TV: the server has no programme listings for the channel")
                    .font(.app(18))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func brief(_ channel: LiveChannel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(name(of: channel).uppercased())
                .font(.app(11, .heavy))
                .kerning(1.2)
                .foregroundStyle(Theme.palette[2].1)
                .lineLimit(1)
            HStack(spacing: 6) {
                if let note = highlight.program?.recordingNote(at: model.now) { LiveRecordingDot(says: note) }
                Text(highlight.program?.name ?? channel.name)
                    .font(.app(19, .bold))
                    .lineLimit(1)
            }
            if let program = highlight.program {
                Text(program.isOn(at: model.now) ? [LiveClock.span(program), LiveClock.left(program, at: model.now)].joined(separator: " · ")
                                                 : LiveClock.span(program))
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Theme.pageMargin)
        .padding(.top, 10)
    }
}

// MARK: - Full screen

/// The channel filling the screen. The remote is as it is for a film: left
/// and right go back and forward through what the channel has sent since it
/// was tuned, and Play/Pause holds it; down brings up a card saying what's
/// on, and with the card up left and right are the channel before and
/// after; up is the captions and the sound's timing; Select brings up
/// what's on and, where it can be recorded, asks whether to; Back returns
/// to the guide, the channel still playing in its corner. By touch the
/// banner has buttons for the same.
struct LiveWatchView: View {
    @ObservedObject var model: LiveTVModel
    @ObservedObject var tuner: LiveTuner
    @ObservedObject var highlight: LiveHighlight
    let close: () -> Void

    @Environment(\.appState) private var app
    @State private var bannerUp = true
    @State private var hiding: Task<Void, Never>?
    /// What's on, being asked about: whether to record it.
    @State private var asked: LiveAsked?
    /// The card a press down brings up: what's on, described.
    @State private var showingInfo = false
    /// The channel that card has been moved along to, where it isn't the
    /// one playing: looked at, not tuned. Under the card is a strip of the
    /// channels, and left and right go along it; Select tunes the one it
    /// stops at. What else is on is seen without leaving the picture, and
    /// without a tuner taken for every channel passed over.
    @State private var surfing: String?
    /// A held press goes along the strip at so many channels a second:
    /// what's left over between one tick and the next.
    @State private var surfCarry = 0.0
    /// By touch, the channels are a list from a button on the banner.
    @State private var channelsUp = false
    /// The picture for that card, and the programme it's a picture of.
    @State private var infoPicture: (program: String, url: URL)?
    /// The list of captions, while it's up: the line the presses have
    /// reached. By touch they're asked about from their button instead.
    @State private var captionLine: Int?
    @State private var captionsAsked = false
    /// The list that moves the sound against the picture, opened from the
    /// foot of the captions' list: the line the presses have reached.
    @State private var syncLine: Int?
    /// Dialogue Boost, at the foot of Audio Sync's list.
    @ObservedObject private var clarity = AudioClarity.shared
    /// The sleep timer's list, opened from the foot of the captions' list
    /// under Audio Sync: the line the presses have reached.
    @State private var sleepLine: Int?
    @State private var sleepAsked = false
    @State private var sleepToken: UUID?
    @ObservedObject private var sleep = SleepTimer.shared
    /// Where the picture is being taken to, in seconds behind the
    /// broadcast, while the presses are still coming: it's gone to once
    /// they stop, in one move.
    @State private var shiftingTo: TimeInterval?
    @State private var settling: Task<Void, Never>?
    /// The line that shows where the picture is in what's kept: up while
    /// it's being moved or held, and for a few seconds after.
    @State private var shiftBarUp = false
    @State private var shiftBarHiding: Task<Void, Never>?
    #if os(tvOS)
    /// Several channels at once, while it's up (see `LiveWall`).
    @State private var wall: LiveWall?
    @State private var wallSleep: UUID?
    @Environment(\.scenePhase) private var scenePhase
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            LiveSurface(tuner: tuner, showing: true)
                .ignoresSafeArea()
                .allowsHitTesting(false)
                .opacity(tuner.shows(highlight.playing?.id) ? 1 : 0)
            if !tuner.shows(highlight.playing?.id) { status }

            #if os(tvOS)
            if wall == nil {
            RemoteSurface(actions: RemoteSurface.Actions(
                select: {
                    if let line = sleepLine { choose(sleepAt: line) }
                    else if let line = syncLine { choose(syncAt: line) }
                    else if let line = captionLine { choose(captionAt: line) }
                    else if showingInfo { chooseSurfed() }
                    else { showBanner(); ask() }
                },
                playPause: {
                    sleepLine = nil; syncLine = nil; captionLine = nil; showingInfo = false; surfing = nil
                    guard tuner.shifts else { return showBanner() }
                    hold()
                },
                menu: { back() },
                // As a film has them: up for the words on the screen, down
                // for what's playing. Within a list they move along it.
                up: {
                    if let line = sleepLine { sleepLine = max(line - 1, 0) }
                    else if let line = syncLine { syncLine = max(line - 1, 0) }
                    else if let line = captionLine { captionLine = max(line - 1, 0) }
                    else if showingInfo { showingInfo = false; surfing = nil }
                    else { captionLine = (captionLines.firstIndex { $0.chosen } ?? 0) + captionsFrom }
                },
                down: {
                    if let line = sleepLine { sleepLine = min(line + 1, sleepLines.count - 1) }
                    else if let line = syncLine { syncLine = min(line + 1, syncLines.count - 1) }
                    else if let line = captionLine { captionLine = min(line + 1, captionsFrom + captionLines.count + 1) }
                    else { showingInfo.toggle(); surfing = nil }
                },
                // A click, not a finger brushing the surface. Back ten
                // seconds or on thirty, as in a film; with the card of
                // what's on up, along the channels under it, the card
                // saying what's on each (nothing is tuned until one is
                // chosen).
                tap: { direction in
                    guard captionLine == nil, syncLine == nil, sleepLine == nil else { return }
                    if showingInfo {
                        surf(direction > 0 ? 1 : -1)
                    } else if !tuner.shifts {
                        model.step(direction > 0 ? 1 : -1)
                        showBanner()
                    } else {
                        shift(by: direction < 0 ? -10 : 30)
                    }
                },
                // Held, it runs: ten seconds of the broadcast a second to
                // begin with, twice that for each second it's held, up to
                // two minutes a second.
                hold: { direction, held, step in
                    if showingInfo, captionLine == nil, syncLine == nil, sleepLine == nil {
                        // Along the channels: six a second, and faster the
                        // longer it's held.
                        surfCarry += step * min(6 + held * 8, 30)
                        while surfCarry >= 1 {
                            surfCarry -= 1
                            surf(direction > 0 ? 1 : -1)
                        }
                        return
                    }
                    guard captionLine == nil, syncLine == nil, sleepLine == nil, !showingInfo, tuner.shifts else { return }
                    shift(by: direction * min(10 * pow(2, held), 120) * step)
                }))
                .tvExitCommand { back() }
                .accessibilityLabel(Text(highlight.playing?.name ?? ""))
                .ignoresSafeArea()
            }
            #elseif os(macOS)
            // A click shows or hides the banner, as a tap does, and the keyboard
            // works it: up and down change channel, as the banner's arrows do;
            // left and right go back ten seconds or on thirty, held they run,
            // where the channel can be paused; space pauses; Escape is back.
            RemoteSurface(actions: RemoteSurface.Actions(
                playPause: {
                    guard tuner.shifts else { return showBanner() }
                    hold()
                },
                menu: { back() },
                up: { model.step(1); showBanner() },
                down: { model.step(-1); showBanner() },
                tap: { direction in
                    guard tuner.shifts else { return }
                    shift(by: direction < 0 ? -10 : 30)
                },
                hold: { direction, held, step in
                    guard tuner.shifts else { return }
                    shift(by: direction * min(10 * pow(2, held), 120) * step)
                },
                touch: { _ in bannerUp ? hideBanner() : showBanner() }))
                .accessibilityLabel(Text(highlight.playing?.name ?? ""))
                .ignoresSafeArea()
            #else
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { bannerUp ? hideBanner() : showBanner() }
                .ignoresSafeArea()
            #endif

            if bannerUp, !shiftBarUp, !showingInfo, captionLine == nil, syncLine == nil, sleepLine == nil, let channel = highlight.playing {
                banner(channel)
                    .transition(.opacity)
            }
            #if !os(tvOS)
            if bannerUp || shiftBarUp, tuner.shifts {
                transport
                    .transition(.opacity)
            }
            #endif
            #if os(tvOS)
            if showingInfo, let channel = shownChannel {
                infoCard(channel)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let line = sleepLine {
                sleepColumn(lit: line)
                    .transition(.opacity)
            } else if let line = syncLine {
                syncColumn(lit: line)
                    .transition(.opacity)
            } else if let line = captionLine {
                captionColumn(lit: line)
                    .transition(.opacity)
            }
            #endif
            #if os(tvOS)
            if let wall {
                LiveWallView(wall: wall, channels: model.channels.filter(\.isFavorite) + model.channels.filter { !$0.isFavorite },
                             showing: { model.current(on: $0) },
                             logo: { app?.client?.channelLogoURL($0, maxWidth: 200) }, leave: leaveWall)
                    .transition(.opacity)
            }
            #endif
            if !wallUp, tuner.shifts, !showingInfo, captionLine == nil, syncLine == nil, sleepLine == nil {
                if shiftBarUp {
                    shiftBar
                        .transition(.opacity)
                } else if tuner.isPaused || tuner.behind > 0 {
                    // Not as it goes out: said for as long as that's so.
                    behindMark
                        .transition(.opacity)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: shiftBarUp)
        .animation(.easeOut(duration: 0.2), value: bannerUp)
        .animation(.easeOut(duration: 0.25), value: showingInfo)
        .animation(.easeOut(duration: 0.15), value: captionLine == nil)
        .overlay { SleepCountdown() }
        .onAppear {
            showBanner()
            // Run out: the channel let go of, and the picture closed.
            let tuner = tuner, close = close
            sleepToken = SleepTimer.shared.register { [weak tuner] in
                tuner?.stop()
                close()
            }
        }
        #if os(tvOS)
        // Put away with the wall up: its channels let go, and the one lit is
        // the one the page takes up again when the app comes back.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .background, let wall else { return }
            if let lit = wall.tiles.indices.contains(wall.lit) ? wall.tiles[wall.lit].channel : wall.tiles.first?.channel {
                highlight.playing = lit
            }
            wall.close()
            SleepTimer.shared.forget(wallSleep)
            self.wall = nil
            model.wallUp = false
        }
        .animation(.easeOut(duration: 0.2), value: wall == nil)
        #if DEBUG
        // -goosetv.debug.wall <id,id,id>: the wall up as the full screen
        // opens, with these channels beside the one playing (for pictures).
        .task {
            guard let ids = UserDefaults.standard.string(forKey: "goosetv.debug.wall"), wall == nil else { return }
            try? await Task.sleep(for: .seconds(2))
            openWall()
            for (place, id) in ids.split(separator: ",").enumerated() {
                if let channel = model.channels.first(where: { $0.id == String(id) }) { wall?.put(channel, at: place + 1) }
            }
        }
        #endif
        #endif
        // A film asked for from another device (see `RemoteControl`): the
        // channel goes, and the full screen with it.
        .onReceive(NotificationCenter.default.publisher(for: RemoteControl.takingOver)) { _ in
            tuner.stop()
            close()
        }
        .onDisappear {
            #if os(tvOS)
            wall?.close()
            model.wallUp = false
            SleepTimer.shared.forget(wallSleep)
            #endif
            SleepTimer.shared.forget(sleepToken)
            hiding?.cancel(); settling?.cancel(); shiftBarHiding?.cancel()
            // The corner of the guide shows the channel as it goes out, and
            // has nothing to say otherwise.
            tuner.catchUp()
        }
        // Another channel has nothing kept yet, and is watched as it goes out.
        .onChange(of: highlight.playing?.id) { _, _ in
            settling?.cancel()
            shiftingTo = nil
            shiftBarUp = false
            surfing = nil
        }
        // The banner stays while the question is up (by touch it's asked
        // from a button on the banner), and for its few seconds after.
        .onChange(of: asked) { _, asked in if asked == nil { showBanner() } }
        .onChange(of: captionsAsked) { _, asking in if !asking { showBanner() } }
        .onChange(of: sleepAsked) { _, asking in if !asking { showBanner() } }
        .onChange(of: channelsUp) { _, up in if !up { showBanner() } }
        // The card's picture, of whatever is on as the card comes up and as
        // one programme gives way to the next under it.
        .task(id: showingInfo ? shownChannel.flatMap { model.current(on: $0)?.id } : nil) { await findInfoPicture() }
        // What's on is being recorded: the way back goes past the tuning,
        // to the programme's beginning.
        .task(id: [highlight.playing?.id, recordingTimer]) { await reachIntoRecording() }
        #if os(tvOS)
        .modifier(LiveAsking(asked: asked, isPresented: $asked.isPresent(), model: model, watch: nil))
        #endif
        // Said here, over the picture: the page under it can't show
        // anything, and opened from Home there's no page.
        .alert(model.recordingProblem ?? "", isPresented: $model.recordingProblem.isPresent()) {}
        .persistentSystemOverlays(.hidden)
    }

    /// The timer the server is recording what's on by, on the channel
    /// that's playing, where it is recording it.
    private var recordingTimer: String? {
        guard let channel = highlight.playing, let program = model.current(on: channel), program.isOn(at: model.now) else { return nil }
        return program.timerId
    }

    /// Gives the tuner the recording to go back through. The channel is a
    /// moment coming, and the server half a minute listing a recording it
    /// has only now begun: looked for until it's there, for a few minutes.
    private func reachIntoRecording() async {
        guard let timer = recordingTimer, let channel = highlight.playing?.id else {
            tuner.reach(into: nil)
            return
        }
        let patience = Date().addingTimeInterval(240)
        while !Task.isCancelled, Date() < patience, tuner.recordingTimer != timer {
            guard tuner.phase == .playing, tuner.channelId == channel else {
                try? await Task.sleep(for: .milliseconds(500))
                continue
            }
            if let found = await model.recording(for: timer) {
                if !Task.isCancelled, tuner.channelId == channel, tuner.recordingTimer != timer { tuner.reach(into: found) }
                return
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    /// Asks what's to be done about recording what's on, where anything can be.
    private func ask() {
        guard let channel = highlight.playing, let program = model.current(on: channel),
              !model.recordings(for: program).isEmpty else { return }
        asked = LiveAsked(channel: channel, program: program)
    }

    /// Back puts away whatever is up, and leaves the channel from a bare picture.
    private func back() {
        if sleepLine != nil { sleepLine = nil }
        else if syncLine != nil { syncLine = nil }
        else if captionLine != nil { captionLine = nil }
        else if showingInfo { showingInfo = false; surfing = nil }
        else { close() }
    }

    // MARK: Along the channels

    /// The channels the card goes along: the guide's as it's narrowed
    /// (favourites, the news), where the one playing is among them, and
    /// all of them where it isn't.
    private var surfList: [LiveChannel] {
        let playing = highlight.playing?.id
        return model.shown.contains { $0.id == playing } ? model.shown : model.channels
    }

    /// The channel the card describes: the one it's been moved to, or the
    /// one playing.
    private var shownChannel: LiveChannel? {
        if let surfing, let found = model.channels.first(where: { $0.id == surfing }) { return found }
        return highlight.playing
    }

    private func surf(_ offset: Int) {
        let list = surfList
        guard list.count > 1 else { return }
        let at = list.firstIndex { $0.id == (surfing ?? highlight.playing?.id) } ?? 0
        let next = list[((at + offset) % list.count + list.count) % list.count].id
        surfing = next == highlight.playing?.id ? nil : next
    }

    /// Select, with the card up: the channel it's been moved to is tuned,
    /// and the card goes. On the one that's playing, the card goes.
    private func chooseSurfed() {
        let chosen = surfing.flatMap { id in model.channels.first { $0.id == id } }
        showingInfo = false
        surfing = nil
        guard let chosen, chosen.id != highlight.playing?.id else { return }
        model.tune(chosen)
        showBanner()
    }

    // MARK: Back through the broadcast

    /// Moves the picture so many seconds on (back, below nought) through
    /// what's kept. The presses add up, and the picture goes where they
    /// leave it once they stop: each move is the player started again from
    /// another place, which is no thing to do thirty times a second.
    private func shift(by seconds: TimeInterval) {
        let from = shiftingTo ?? tuner.behind(at: Date())
        var to = min(max(from - seconds, 0), max(tuner.reach - 2, 0))
        // Forward to within a few seconds of the broadcast is forward to
        // the broadcast: nobody means to watch four seconds late.
        if seconds > 0, to < 8 { to = 0 }
        shiftingTo = to
        showShiftBar()
        settling?.cancel()
        settling = Task {
            try? await Task.sleep(for: .milliseconds(550))
            guard !Task.isCancelled else { return }
            // Not for a nudge that leaves it where it is: forward, with
            // nothing ahead but the broadcast itself.
            if abs(to - tuner.behind(at: Date())) >= 1 { tuner.go(behind: to) }
            shiftingTo = nil
            showShiftBar()
        }
    }

    #if !os(tvOS)
    /// Back ten, hold or play, forward ten, in the middle of the picture,
    /// as a film has them.
    private var transport: some View {
        HStack(spacing: 56) {
            touchButton("gobackward.10", size: 30, label: String(localized: "Back 10 seconds")) { shift(by: -10) }
            touchButton(tuner.isPaused ? "play.fill" : "pause.fill", size: 44,
                        label: tuner.isPaused ? String(localized: "Play") : String(localized: "Pause")) {
                hold()
            }
            touchButton("goforward.10", size: 30, label: String(localized: "Forward 10 seconds")) { shift(by: 10) }
        }
    }

    private func touchButton(_ icon: String, size: CGFloat, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 2.1, height: size * 2.1)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    #endif

    /// Holds the picture, or lets it go on. A move still waiting on its
    /// last press is made first: left to itself it came half a second
    /// later and set the picture going again.
    private func hold() {
        if let to = shiftingTo {
            settling?.cancel()
            shiftingTo = nil
            if abs(to - tuner.behind(at: Date())) >= 1 { tuner.go(behind: to) }
        }
        if tuner.isPaused { tuner.resume() } else { tuner.pause() }
        showShiftBar()
    }

    private func showShiftBar() {
        shiftBarUp = true
        shiftBarHiding?.cancel()
        shiftBarHiding = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, shiftingTo == nil { shiftBarUp = false }
        }
    }

    /// "2:35" behind, as it's written on the bar and the mark.
    private static func behindText(_ seconds: TimeInterval) -> String {
        "−" + Duration.seconds(seconds.rounded()).formatted(.time(pattern: seconds >= 3600 ? .hourMinuteSecond : .minuteSecond))
    }

    /// Where the picture is in what's kept: the oldest of it at one end and
    /// the broadcast as it goes out at the other, with the time on the
    /// clock of what's showing and how far behind that is.
    private var shiftBar: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let behind = shiftingTo ?? tuner.behind(at: context.date)
            let reach = max(tuner.reach, behind, 1)
            HStack(spacing: 18) {
                Image(systemName: tuner.isPaused && shiftingTo == nil ? "pause.fill" : "play.fill")
                    .font(.app(20, .bold))
                    .frame(width: CGFloat(26).scaled)
                Text(LiveClock.time(context.date.addingTimeInterval(-behind)))
                    .font(.app(20, .semibold))
                    .monospacedDigit()
                    .fixedSize()
                GeometryReader { geo in
                    let at = geo.size.width * (1 - behind / reach)
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.25))
                        Capsule().fill(Theme.gradient(Theme.primary, start: .leading, end: .trailing))
                            .frame(width: max(at, 0))
                        Circle().fill(.white)
                            .frame(width: 16, height: 16)
                            .offset(x: min(max(at - 8, 0), geo.size.width - 16))
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 16)
                Group {
                    if behind < 4 { LiveBadge() } else { Text(Self.behindText(behind)).font(.app(20, .semibold)).monospacedDigit() }
                }
                .frame(minWidth: CGFloat(96).scaled, alignment: .trailing)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 28)
            .padding(.vertical, 18)
            .background {
                Capsule().fill(.black.opacity(0.6))
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay { Capsule().strokeBorder(.white.opacity(0.12), lineWidth: 1) }
            }
            .frame(maxWidth: CGFloat(1200).scaled)
            .padding(.horizontal, 40)
            .padding(.bottom, CGFloat(60).scaled)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .allowsHitTesting(false)
    }

    /// In the corner while the picture isn't the broadcast as it goes out:
    /// how far behind, and whether it's held.
    private var behindMark: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 9) {
                if tuner.isPaused { Image(systemName: "pause.fill").font(.app(14, .bold)) }
                Text(Self.behindText(tuner.behind(at: context.date)))
                    .font(.app(17, .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
            .padding(.trailing, CGFloat(48).scaled)
            #if !os(tvOS)
            // Under the banner's buttons while they're up: it sat on them.
            .padding(.top, CGFloat(44).scaled + (bannerUp ? 56 : 0))
            #else
            .padding(.top, CGFloat(44).scaled)
            #endif
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .allowsHitTesting(false)
    }

    // MARK: Captions

    private struct CaptionLine {
        let id: Int32?
        let title: String
        let chosen: Bool
    }

    /// Where the captions begin in the list a press up opens: Multiview is
    /// above them on the Apple TV.
    private var captionsFrom: Int {
        #if os(tvOS)
        1
        #else
        0
        #endif
    }

    /// None, then each set the channel carries.
    private var captionLines: [CaptionLine] {
        [CaptionLine(id: nil, title: String(localized: "Off", comment: "Subtitles turned off"), chosen: tuner.caption == nil)]
            + tuner.captions.map { CaptionLine(id: $0.id, title: $0.name, chosen: $0.id == tuner.caption) }
    }

    private func choose(captionAt line: Int) {
        #if os(tvOS)
        // Above them, several channels at once.
        if line == 0 { captionLine = nil; return openWall() }
        #endif
        let lines = captionLines
        let line = line - captionsFrom
        // The lines under the last of them open the sound's list, and the
        // sleep timer's.
        if line == lines.count { return syncLine = 0 }
        if line == lines.count + 1 { return sleepLine = sleepLines.firstIndex { $0.chosen } ?? 0 }
        if lines.indices.contains(line) { tuner.show(caption: lines[line].id) }
        captionLine = nil
        showBanner()
    }

    // MARK: Multiview

    /// Whether several channels are up at once (the Apple TV's alone).
    private var wallUp: Bool {
        #if os(tvOS)
        wall != nil
        #else
        false
        #endif
    }

    #if os(tvOS)
    /// The wall goes up with the channel that's on in its first place, and
    /// the channels to choose the next from. The full screen's tuner is let
    /// go once the wall's has the channel: the server has one stream for a
    /// channel, however many are on it, so nothing is tuned twice.
    private func openWall() {
        guard let client = app?.client, let playing = highlight.playing else { return }
        let wall = LiveWall(client: client)
        wall.put(playing, at: 0)
        self.wall = wall
        model.wallUp = true
        let tuner = tuner
        wallSleep = SleepTimer.shared.register { [weak wall] in
            wall?.close()
            tuner.stop()
            close()
        }
        Task {
            for _ in 0..<30 where wall.tiles.first?.phase == .tuning {
                try? await Task.sleep(for: .milliseconds(500))
            }
            if self.wall === wall { tuner.stop() }
        }
    }

    /// Back to the full screen, on this channel: the full screen's tuner
    /// shares the wall's stream for it, which is held until that's playing.
    private func leaveWall(_ channel: LiveChannel?) {
        guard let wall else { return }
        SleepTimer.shared.forget(wallSleep)
        self.wall = nil
        model.wallUp = false
        guard let channel else { return wall.close() }
        model.tune(channel)
        let tuner = tuner
        wall.close(keeping: channel.id) {
            for _ in 0..<30 where tuner.phase != .playing {
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        showBanner()
    }
    #endif

    // MARK: Sound against picture

    private static var syncTitle: String {
        String(localized: "Audio Sync", comment: "Menu in the player that moves the sound earlier or later against the picture")
    }

    /// A nudge at a time, as the film player has it, each line saying where
    /// it would leave the sound: the list stays up, so the same line is
    /// pressed again until the lips and the words agree.
    /// Under them, Dialogue Boost, on or off by a press.
    private var syncLines: [(title: String, trailing: String?, chosen: Bool, choose: () -> Void)] {
        let current = tuner.soundDelay
        let later = AudioSync.nudged(current, by: 1), earlier = AudioSync.nudged(current, by: -1)
        let tuner = tuner, clarity = clarity
        return [(String(localized: "Later", comment: "In the player's Audio Sync menu: moves the sound a little later against the picture"),
                 later == current ? nil : AudioSync.label(later), false, { tuner.set(soundDelay: later) }),
                (String(localized: "Earlier", comment: "In the player's Audio Sync menu: moves the sound a little earlier against the picture"),
                 earlier == current ? nil : AudioSync.label(earlier), false, { tuner.set(soundDelay: earlier) }),
                (AudioSync.label(0), nil, current == 0, { tuner.set(soundDelay: 0) }),
                (AudioClarityText.dialogue, nil, clarity.dialogueBoost, { clarity.dialogueBoost.toggle() })]
    }

    private func choose(syncAt line: Int) {
        let lines = syncLines
        if lines.indices.contains(line) { lines[line].choose() }
    }

    // MARK: Sleep

    /// Off, the lengths, and the end of what's on (where the guide says
    /// when that is): a time, as a programme's end is.
    private var sleepLines: [(title: String, chosen: Bool, choose: () -> Void)] {
        let timer = SleepTimer.shared
        var lines: [(title: String, chosen: Bool, choose: () -> Void)] = [
            (String(localized: "Off", comment: "Subtitles turned off"), !timer.isSet, { timer.cancel() }),
        ]
        lines += SleepTimer.lengths.map { minutes in (SleepTimer.length(minutes), false, { timer.set(minutes: minutes) }) }
        if let channel = highlight.playing, let program = model.current(on: channel), program.end > model.now {
            lines.append((SleepTimer.whenThisEnds, timer.ends == program.end, { timer.set(until: program.end) }))
        }
        return lines
    }

    private func choose(sleepAt line: Int) {
        let lines = sleepLines
        if lines.indices.contains(line) { lines[line].choose() }
        sleepLine = nil
        captionLine = nil
        showBanner()
    }

    #if os(tvOS)
    private func sleepColumn(lit: Int) -> some View {
        PlayerPanelColumn(title: SleepTimer.title, accent: Theme.palette[1]) {
            ForEach(Array(sleepLines.enumerated()), id: \.offset) { index, line in
                PlayerPanelRow(title: line.title, chosen: line.chosen)
                    .foregroundStyle(index == lit ? Color.black : Color.white)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(index == lit ? Color.white : Color.clear)
                    }
            }
        }
        .frame(maxWidth: CGFloat(760).scaled, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 80)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }
    #endif

    private static var captionsTitle: String {
        String(localized: "Captions", comment: "Live TV: the words of what's said, sent with a broadcast, shown over the picture")
    }

    /// Said under an empty list: a broadcast's captions aren't known of
    /// until some have been sent.
    private static var noCaptions: String {
        String(localized: "This channel hasn't sent any captions yet.", comment: "Live TV: the channel being watched has carried no captions so far")
    }

    #if os(tvOS)
    /// The list a press up opens, at the foot of the screen on the right,
    /// with the line the presses have reached lit.
    private func captionColumn(lit: Int) -> some View {
        let lines = captionLines
        let from = captionsFrom
        return PlayerPanelColumn(title: Self.captionsTitle, accent: Theme.palette[2]) {
            // Several channels at once.
            PlayerPanelRow(title: LiveWallView.title, chosen: false)
                .foregroundStyle(lit == 0 ? Color.black : Color.white)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(lit == 0 ? Color.white : Color.clear)
                }
        } content: {
            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                PlayerPanelRow(title: line.title, chosen: line.chosen)
                    .foregroundStyle(from + index == lit ? Color.black : Color.white)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(from + index == lit ? Color.white : Color.clear)
                    }
            }
            if tuner.captions.isEmpty {
                Text(Self.noCaptions)
                    .font(.app(17, .medium))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 6)
            }
            // The sound against the picture, a list of its own.
            PlayerPanelRow(title: Self.syncTitle, trailing: AudioSync.label(tuner.soundDelay), chosen: false)
                .foregroundStyle(lit == from + lines.count ? Color.black : Color.white)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(lit == from + lines.count ? Color.white : Color.clear)
                }
            PlayerPanelRow(title: SleepTimer.title, trailing: sleep.summary(), chosen: false)
                .foregroundStyle(lit == from + lines.count + 1 ? Color.black : Color.white)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(lit == from + lines.count + 1 ? Color.white : Color.clear)
                }
        }
        .frame(maxWidth: CGFloat(760).scaled, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 80)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private func syncColumn(lit: Int) -> some View {
        PlayerPanelColumn(title: Self.syncTitle, accent: Theme.palette[0]) {
            ForEach(Array(syncLines.enumerated()), id: \.offset) { index, line in
                PlayerPanelRow(title: line.title, trailing: line.trailing, chosen: line.chosen)
                    .foregroundStyle(index == lit ? Color.black : Color.white)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(index == lit ? Color.white : Color.clear)
                    }
            }
        }
        .frame(maxWidth: CGFloat(760).scaled, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.trailing, 80)
        .padding(.bottom, 60)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
    }

    // MARK: Info

    /// What's on, risen from the bottom of the screen as a film's card is:
    /// the programme's picture where the listings have one, its name, when
    /// it's on and what it's about.
    private func infoCard(_ channel: LiveChannel) -> some View {
        let program = model.current(on: channel)
        let picture = infoPicture.flatMap { $0.program == program?.id ? $0.url : nil }
        return VStack(alignment: .leading, spacing: 26) {
        HStack(alignment: .top, spacing: 36) {
            ZStack {
                Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing).opacity(0.4)
                if let picture {
                    // Whole, whatever its shape: the listings' pictures are
                    // as often a poster with the name along its foot.
                    RemoteImage(url: picture, contentMode: .fit)
                } else if let logo = app?.client?.channelLogoURL(channel, maxWidth: 320) {
                    // No picture of the programme: the station's mark.
                    RemoteImage(url: logo, contentMode: .fit)
                        .padding(.horizontal, CGFloat(90).scaled)
                        .padding(.vertical, CGFloat(50).scaled)
                }
            }
            .frame(width: CGFloat(400).scaled, height: CGFloat(225).scaled)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    LiveBadge()
                    Text([channel.number, channel.name].compactMap { $0 }.joined(separator: " · ").uppercased())
                        .font(.app(15, .heavy))
                        .kerning(1.4)
                        .foregroundStyle(Theme.palette[2].1)
                        .lineLimit(1)
                    if channel.id != highlight.playing?.id {
                        // Looked at, not on: what a press of Select does.
                        Text("Select to Watch", comment: "Live TV: over a channel that's being looked at in the strip of channels and isn't the one playing; pressing Select tunes it")
                            .font(.app(14, .bold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(.white.opacity(0.16), in: Capsule())
                    }
                }
                Text(program?.name ?? channel.name)
                    .font(.app(34, .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let program {
                    let episode = program.episodeTitle.flatMap { $0.isEmpty || $0 == program.name ? nil : $0 }
                    if let episode {
                        Text(episode)
                            .font(.app(22, .semibold))
                            .foregroundStyle(.white.opacity(0.9))
                            .lineLimit(1)
                    }
                    HStack(spacing: 12) {
                        Text(LiveClock.span(program))
                        Text(LiveClock.left(program, at: model.now))
                        if let rating = program.rating, !rating.isEmpty {
                            Text(rating)
                                .padding(.horizontal, 7)
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.5), lineWidth: 1.5))
                        }
                        if let note = program.recordingNote(at: model.now) {
                            HStack(spacing: 7) {
                                LiveRecordingDot(size: 10)
                                Text(note)
                            }
                        }
                    }
                    .font(.app(19, .semibold))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                    // As many lines as leave room for what follows: the card
                    // keeps its height, for the strip under it.
                    LiveProgrammeAbout(program: program, font: .app(21), color: .white.opacity(0.85),
                                       lines: episode == nil ? 3 : 2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let next = model.next(on: channel) {
                        Text("Next: \(next.name)", comment: "Live TV banner: the programme that follows; the placeholder is its title")
                            .font(.app(19))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                } else {
                    Text("No guide for this channel.", comment: "Live TV: the server has no programme listings for the channel")
                        .font(.app(21))
                        .foregroundStyle(.white.opacity(0.7))
                }
            }
            Spacer(minLength: 0)
        }
        // A card's height whatever it has to say, so that the strip under
        // it stays where it is as the card goes from channel to channel.
        .frame(height: CGFloat(236).scaled, alignment: .top)
        channelStrip(around: channel)
        }
        .risenCard()
    }

    /// The channels either side of the one the card is on, three each way,
    /// with what's on each: the card's place among them is the lit one.
    private func channelStrip(around channel: LiveChannel) -> some View {
        let list = surfList
        let at = list.firstIndex { $0.id == channel.id }
        let shown: [LiveChannel]
        if let at, list.count > 7 {
            shown = (-3...3).map { list[((at + $0) % list.count + list.count) % list.count] }
        } else {
            shown = at == nil ? [channel] : list
        }
        return HStack(spacing: 12) {
            ForEach(shown) { item in
                let program = model.current(on: item)
                let lit = item.id == channel.id
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        if let logo = app?.client?.channelLogoURL(item, maxWidth: 160) {
                            RemoteImage(url: logo, contentMode: .fit)
                                .frame(width: CGFloat(54).scaled, height: CGFloat(34).scaled)
                        }
                        Text(item.number ?? item.name)
                            .font(.app(14, .heavy))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        if item.id == highlight.playing?.id {
                            // The one that's on.
                            Circle().fill(Color(red: 1, green: 0.42, blue: 0.29)).frame(width: 8, height: 8)
                        } else if program?.isSetToRecord == true {
                            LiveRecordingDot(size: 8)
                        }
                    }
                    .frame(height: CGFloat(34).scaled)
                    Text(program?.name ?? item.name)
                        .font(.app(15, .semibold))
                        .lineLimit(1)
                    WatchProgressBar(fraction: program.map { $0.isOn(at: model.now) ? $0.fraction(at: model.now) : 0 } ?? 0)
                        .opacity(program == nil ? 0 : 1)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundStyle(.white)
                .opacity(lit ? 1 : 0.72)
                // Ringed in white, not filled with it as a control in focus
                // is elsewhere: a station's mark is drawn to stand on the
                // dark, and half of them vanished on white.
                .background(Color.white.opacity(lit ? 0.24 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay {
                    if lit {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white, lineWidth: 3)
                    }
                }
            }
        }
    }
    #endif

    private func findInfoPicture() async {
        guard showingInfo, let channel = shownChannel, let program = model.current(on: channel),
              infoPicture?.program != program.id, let client = app?.client else { return }
        // Not for every channel a held press passes over: for the one it stops at.
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return }
        if let url = await client.liveProgramPictureURL(programId: program.id, maxWidth: 800), !Task.isCancelled {
            infoPicture = (program.id, url)
        }
    }

    private var status: some View {
        VStack(spacing: 16) {
            if let trouble = tuner.phase.trouble { Text(trouble) } else { ProgressView() }
        }
        .font(.app(20))
        .foregroundStyle(.white.opacity(0.8))
        .multilineTextAlignment(.center)
        .padding(40)
    }

    private func banner(_ channel: LiveChannel) -> some View {
        let program = model.current(on: channel)
        return VStack(spacing: 0) {
            #if !os(tvOS)
            HStack {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 44, height: 44)
                        .background(.black.opacity(0.55), in: Circle())
                }
                .accessibilityLabel(Text("Close"))
                Spacer()
                HStack(spacing: 12) {
                    if let program, let first = model.recordings(for: program).first {
                        Button { ask() } label: {
                            Image(systemName: program.isSetToRecord ? "record.circle.fill" : "record.circle")
                                .font(.system(size: 19, weight: .bold))
                                .foregroundStyle(program.isSetToRecord ? recordingRed : .white)
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .accessibilityLabel(Text(model.name(of: first, for: program)))
                        // Asked from the button, which is where it points.
                        .modifier(LiveAsking(asked: asked, isPresented: $asked.isPresent(), model: model, watch: nil))
                    }
                    Button { captionsAsked = true } label: {
                        Image(systemName: tuner.caption == nil ? "captions.bubble" : "captions.bubble.fill")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(Text(Self.captionsTitle))
                    // Asked from the button, which is where it points.
                    .confirmationDialog(Self.captionsTitle, isPresented: $captionsAsked, titleVisibility: .visible) {
                        ForEach(Array(captionLines.enumerated()), id: \.offset) { _, line in
                            Button(line.chosen ? "✓ " + line.title : line.title) { tuner.show(caption: line.id) }
                        }
                    } message: {
                        if tuner.captions.isEmpty { Text(Self.noCaptions) }
                    }
                    Button { sleepAsked = true } label: {
                        Image(systemName: sleep.isSet ? "moon.zzz.fill" : "moon.zzz")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(Text(SleepTimer.title))
                    .confirmationDialog(SleepTimer.title, isPresented: $sleepAsked, titleVisibility: .visible) {
                        ForEach(Array(sleepLines.enumerated()), id: \.offset) { _, line in
                            Button(line.chosen ? "✓ " + line.title : line.title) { line.choose() }
                        }
                    } message: {
                        if sleep.isSet { Text(sleep.summary()) }
                    }
                    Button { channelsUp = true } label: {
                        Image(systemName: "list.bullet")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(Text("Channels", comment: "Button over a television picture: lists the channels with what's on each"))
                    .sheet(isPresented: $channelsUp) {
                        LiveChannelList(model: model, playing: channel.id,
                                        logo: { app?.client?.channelLogoURL($0, maxWidth: 160) }) { chosen in
                            channelsUp = false
                            if chosen.id != channel.id { model.tune(chosen) }
                            showBanner()
                        }
                        .presentationDetents([.medium, .large])
                        .presentationBackground(Theme.background)
                    }
                    Button { model.step(-1); showBanner() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(Text("Channel down", comment: "Button: the previous television channel"))
                    Button { model.step(1); showBanner() } label: {
                        Image(systemName: "chevron.up")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel(Text("Channel up", comment: "Button: the next television channel"))
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.top, 14)
            #endif
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    if !tuner.isPaused, tuner.behind == 0 { LiveBadge() }
                    Text([channel.number, channel.name].compactMap { $0 }.joined(separator: " · ").uppercased())
                        .font(.app(15, .heavy))
                        .kerning(1.4)
                        .foregroundStyle(Theme.palette[2].1)
                        .lineLimit(1)
                    if let note = program?.recordingNote(at: model.now) {
                        HStack(spacing: 7) {
                            LiveRecordingDot(size: 10)
                            Text(note.uppercased())
                                .font(.app(15, .heavy))
                                .kerning(1.2)
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .accessibilityElement(children: .combine)
                    }
                    Spacer()
                    Text(LiveClock.time(model.now))
                        .font(.app(18, .semibold))
                        .foregroundStyle(.white.opacity(0.8))
                }
                Text(program?.name ?? channel.name)
                    .font(.app(38, .bold))
                    .lineLimit(1)
                if let program {
                    HStack(spacing: 16) {
                        Text(LiveClock.span(program))
                            .lineLimit(1)
                            .fixedSize()
                        LiveProgressLine(fraction: program.fraction(at: model.now), height: 5)
                            .frame(maxWidth: CGFloat(360).scaled)
                        Text(LiveClock.left(program, at: model.now))
                            .lineLimit(1)
                            .fixedSize()
                        if let next = model.next(on: channel) {
                            Spacer(minLength: 20)
                            Text("Next: \(next.name)", comment: "Live TV banner: the programme that follows; the placeholder is its title")
                                .lineLimit(1)
                        }
                    }
                    .font(.app(19))
                    .foregroundStyle(.white.opacity(0.8))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, CGFloat(64).scaled)
            .padding(.top, 60)
            .padding(.bottom, CGFloat(54).scaled)
            .background {
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .ignoresSafeArea()
            }
        }
    }

    private func showBanner() {
        bannerUp = true
        hiding?.cancel()
        hiding = Task {
            try? await Task.sleep(for: .seconds(5))
            if !Task.isCancelled, asked == nil, !captionsAsked, !sleepAsked, !channelsUp { bannerUp = false }
        }
    }

    private func hideBanner() {
        hiding?.cancel()
        bannerUp = false
    }
}
