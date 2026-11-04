import SwiftUI

/// What Search finds in the TV listings: programmes by name, each with its
/// showings to come, and channels by name or number. The programmes are
/// asked of the server as the titles are; the channels, a hundred or so, are
/// fetched the once and looked through here.
@MainActor
final class LiveSearch: ObservableObject {
    @Published private(set) var shows: [LiveShow] = []
    @Published private(set) var channels: [BaseItem] = []
    /// Every channel, with what was on it when they were fetched: what's
    /// looked through for the words, and what a showing is watched on.
    private var allChannels: [BaseItem]?

    func search(_ term: String, with client: any MediaServer) async {
        if allChannels == nil { allChannels = try? await client.liveOnNow(first: nil, limit: 10_000) }
        let found = (try? await client.liveSearch(term)) ?? []
        guard !Task.isCancelled else { return }
        shows = LiveShow.group(found, for: term)
        channels = (allChannels ?? []).filter { Self.channel($0, matches: term) }
    }

    func clear() {
        shows = []
        channels = []
    }

    /// The channel a showing is on, as the server lists it, to be watched.
    func channel(_ id: String?) -> BaseItem? {
        allChannels?.first { $0.id == id }
    }

    /// The show again, as the server has it now: after a recording of it was
    /// set or taken off. Nil where it couldn't be asked, or nothing of it is
    /// to come any more.
    func again(_ show: LiveShow, with client: any MediaServer) async -> LiveShow? {
        guard let found = try? await client.liveSearch(show.name),
              let fresh = LiveShow.group(found, for: show.name).first(where: { $0.id == show.id }) else { return nil }
        if let at = shows.firstIndex(where: { $0.id == show.id }) { shows[at] = fresh }
        return fresh
    }

    /// By its name, or by its number from the start: "35" finds 35.1.
    private static func channel(_ channel: BaseItem, matches term: String) -> Bool {
        let words = term.trimmingCharacters(in: .whitespaces)
        if let number = channel.channelNumber, number.hasPrefix(words) { return true }
        return channel.name?.range(of: words, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

/// A programme the listings have by one name, with its showings to come,
/// earliest first: the evening news is found once, not once a night.
struct LiveShow: Identifiable, Hashable {
    let name: String
    let showings: [LiveListing]

    var id: String { name.lowercased() }
    var next: LiveListing { showings[0] }
    /// The first of its showings that came with a picture.
    var pictured: LiveListing? { showings.first { $0.imageTag != nil } }
    var isSetToRecord: Bool { showings.contains { $0.program.isSetToRecord } }
    /// What it's about, from the first showing that says.
    var overview: String? { showings.lazy.compactMap(\.program.overview).first { !$0.isEmpty } }

    static func == (a: Self, b: Self) -> Bool { a.id == b.id && a.showings == b.showings }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    /// The showings put together by name, in the order someone typing the
    /// words most likely meant: the name itself, then one that starts with
    /// them, then one with a word that does, then the rest; and among those
    /// alike, the soonest on.
    static func group(_ listings: [LiveListing], for term: String) -> [LiveShow] {
        var byName: [String: [LiveListing]] = [:]
        var order: [String] = []
        for listing in listings where !listing.program.name.isEmpty {
            let key = listing.program.name.lowercased()
            if byName[key] == nil { order.append(key) }
            byName[key, default: []].append(listing)
        }
        let shows = order.compactMap { key -> LiveShow? in
            guard let all = byName[key]?.sorted(by: { $0.program.start < $1.program.start }), let first = all.first else { return nil }
            return LiveShow(name: first.program.name, showings: all)
        }
        let typed = plain(term)
        func rank(_ show: LiveShow) -> Int {
            let name = plain(show.name)
            if name == typed { return 0 }
            if name.hasPrefix(typed) { return 1 }
            if name.split(separator: " ").contains(where: { $0.hasPrefix(typed) }) { return 2 }
            return 3
        }
        return shows.sorted { a, b in
            let (ra, rb) = (rank(a), rank(b))
            return ra != rb ? ra < rb : a.next.program.start < b.next.program.start
        }
    }

    private static func plain(_ text: String) -> String {
        text.lowercased().folding(options: .diacriticInsensitive, locale: nil).trimmingCharacters(in: .whitespaces)
    }
}

/// A programme among Search's results: its picture, its name, and when and
/// where it's next on. Through to all its showings.
struct LiveShowCard: View {
    @Environment(\.appState) private var app
    let show: LiveShow

    var body: some View {
        let next = show.next
        let width = Theme.landscapeWidth
        let on = next.program.isOn()
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: show) {
                ZStack(alignment: .bottom) {
                    picture
                        .frame(width: width, height: width * 9 / 16)
                        .clipped()
                    if on {
                        WatchProgressBar(fraction: next.program.fraction())
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if on {
                        LiveBadge()
                            .scaleEffect(0.85, anchor: .topLeading)
                            .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    // Set to record, as the guide marks it.
                    if show.isSetToRecord {
                        LiveRecordingDot(size: 11)
                            .padding(7)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(10)
                    }
                }
                .keepsCardCorners()
            }
            .buttonStyle(.tvCard)
            .accessibilityLabel([show.name, Self.when(next), next.channelLine].joined(separator: ", "))

            VStack(alignment: .leading, spacing: 2) {
                Text(show.name)
                    .font(.app(17))
                    .lineLimit(1)
                Text([Self.when(next), next.channelLine].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
    }

    /// "On Now", or "Today 7:00 PM".
    static func when(_ listing: LiveListing, at now: Date = Date()) -> String {
        listing.program.isOn(at: now)
            ? String(localized: "On Now", comment: "Home row: what's on the television channels at this moment")
            : "\(LiveClock.day(listing.program.start)) \(LiveClock.time(listing.program.start))"
    }

    @ViewBuilder
    private var picture: some View {
        if let pictured = show.pictured, let url = app?.client?.liveListingImageURL(pictured, maxWidth: 800) {
            RemoteImage(url: url)
        } else {
            // No picture in the listings: its name on the theme's colour.
            ZStack {
                Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing).opacity(0.4)
                Text(show.name)
                    .font(.app(22, .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
            }
        }
    }
}

/// One programme's showings to come, from Search: each says when and on
/// which channel, and is chosen to watch its channel, or to record it as the
/// guide records.
struct LiveShowPage: View {
    @EnvironmentObject var app: AppState
    @Environment(\.isNarrow) private var narrow
    @ObservedObject var search: LiveSearch
    @State var show: LiveShow
    @State private var asked: LiveListing?
    @State private var problem: String?
    @State private var watching: Watching?

    /// A channel to fill the screen with: as it is, or from the start of
    /// what the server is recording on it.
    struct Watching: Identifiable {
        let channel: BaseItem
        var start: String?
        var id: String { channel.id + (start ?? "") }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 36) {
                header
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(show.showings) { showing in
                        row(showing)
                    }
                }
                .tvFocusSection()
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, narrow ? 24 : 60)
        }
        .alert(problem ?? "", isPresented: $problem.isPresent()) {}
        // Back from the picture to the showing it was chosen from, not to the
        // menu, which takes focus let go of as the picture closes.
        .fullScreenCover(item: $watching, onDismiss: { app.holdMenuFocus() }) { watch in
            if let client = app.client {
                LiveWatchHost(channel: watch.channel, client: client, start: watch.start)
            }
        }
    }

    private var header: some View {
        let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 20))
                            : AnyLayout(HStackLayout(alignment: .top, spacing: 40))
        let pictureWidth: CGFloat = narrow ? 240 : 480
        return layout {
            if let pictured = show.pictured, let url = app.client?.liveListingImageURL(pictured, maxWidth: 960) {
                RemoteImage(url: url)
                    .frame(width: pictureWidth, height: pictureWidth * 3 / 4)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 12) {
                Text(show.name)
                    .font(.app(narrow ? 28 : 44, .bold))
                    .lineLimit(2)
                Text(count)
                    .font(.app(narrow ? 15 : 20, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                if let overview = show.overview {
                    Text(overview)
                        .font(.app(narrow ? 15 : 22))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(4)
                }
            }
        }
    }

    private var count: String {
        show.showings.count == 1
            ? String(localized: "1 showing", comment: "Search: how many times a television programme is on in the listings")
            : String(localized: "\(show.showings.count) showings", comment: "Search: how many times a television programme is on in the listings")
    }

    private func row(_ showing: LiveListing) -> some View {
        let program = showing.program
        let on = program.isOn()
        return Button { asked = showing } label: {
            HStack(spacing: narrow ? 14 : 28) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(on ? String(localized: "On Now", comment: "Home row: what's on the television channels at this moment")
                            : LiveClock.day(program.start))
                        .font(.app(narrow ? 13 : 16, .semibold))
                        .opacity(0.7)
                    Text(LiveClock.span(program))
                        .font(.app(narrow ? 15 : 20, .semibold))
                        .monospacedDigit()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: narrow ? 118 : 250, alignment: .leading)
                VStack(alignment: .leading, spacing: 3) {
                    Text(showing.channelLine)
                        .font(.app(narrow ? 15 : 20, .semibold))
                        .lineLimit(1)
                    if let episode = program.episodeTitle, !episode.isEmpty {
                        Text(episode)
                            .font(.app(narrow ? 13 : 16))
                            .opacity(0.7)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let note = program.recordingNote(onNow: on) {
                    HStack(spacing: 8) {
                        LiveRecordingDot()
                        if !narrow {
                            Text(note.uppercased())
                                .font(.app(12, .heavy))
                                .kerning(1.2)
                                .opacity(0.75)
                                .lineLimit(1)
                        }
                    }
                }
            }
            .padding(.horizontal, narrow ? 14 : 22)
            .padding(.vertical, narrow ? 12 : 16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(ShowingRowStyle(onNow: on))
        // Said whole, as the row reads: the parts as they were before a
        // recording was set or taken off lingered as the row's own.
        .accessibilityLabel([on ? String(localized: "On Now", comment: "Home row: what's on the television channels at this moment") : LiveClock.day(program.start),
                             LiveClock.span(program), showing.channelLine, program.episodeTitle ?? "",
                             program.recordingNote(onNow: on) ?? ""].filter { !$0.isEmpty }.joined(separator: ", "))
        // Each row its own: by touch the choices point at the showing tapped.
        .confirmationDialog(program.name, isPresented: asking(showing), titleVisibility: .visible) {
            if let channel = search.channel(program.channelId) {
                Button(String(localized: "Watch \(channel.name ?? showing.channelLine)", comment: "Live TV: goes to the channel a later programme is on, as it is now; the placeholder is the channel's name")) {
                    watching = Watching(channel: channel)
                }
            }
            ForEach(choices(for: showing), id: \.self) { choice in
                Button(choice.name(for: program, at: Date()), role: choice.undoes ? .destructive : nil) {
                    take(choice, for: showing)
                }
            }
        } message: {
            Text([LiveClock.day(program.start), LiveClock.span(program), showing.channelLine]
                .filter { !$0.isEmpty }.joined(separator: " · "))
        }
    }

    private func asking(_ showing: LiveListing) -> Binding<Bool> {
        Binding(get: { asked?.id == showing.id }, set: { if !$0, asked?.id == showing.id { asked = nil } })
    }

    /// What can be done about recording it, as anywhere else a programme is
    /// met: watching what's being recorded from its start is anyone's;
    /// setting and stopping is for an account that may record.
    private func choices(for showing: LiveListing) -> [LiveTVModel.Recording] {
        let all = LiveTVModel.Recording.choices(for: showing.program, at: Date())
        return app.liveCanRecord ? all : all.filter { $0 == .fromStart }
    }

    private func take(_ choice: LiveTVModel.Recording, for showing: LiveListing) {
        guard let client = app.client else { return }
        if choice == .fromStart {
            if let channel = search.channel(showing.program.channelId), let timer = showing.program.timerId {
                watching = Watching(channel: channel, start: timer)
            }
            return
        }
        Task {
            do {
                try await choice.send(for: showing.program, to: client)
            } catch {
                problem = choice.failure
            }
            app.liveRecordingChanged()
            // Its showings as the server has them now: the dots where it's set.
            if let fresh = await search.again(show, with: client) { show = fresh }
        }
    }
}

/// A showing's row: lit like the guide's squares when focus is on it, and
/// a little brighter while it's on.
private struct ShowingRowStyle: ButtonStyle {
    let onNow: Bool
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        configuration.label
            .foregroundStyle(focused ? Color(white: 0.06) : .white)
            .background(focused ? Color.white : Color.white.opacity(configuration.isPressed ? 0.2 : (onNow ? 0.13 : 0.06)), in: shape)
            .clipShape(shape)
            .scaleEffect(focused ? 1.02 : 1)
            .animation(.easeOut(duration: 0.12), value: focused)
    }
}
