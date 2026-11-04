import SwiftUI

/// A title as Seerr shows one: where it stands, what it is, the buttons that
/// ask for it (in a panel, as Seerr's is), the requests there are for it with
/// what may be done about each, a show's seasons, who's in it, and what's
/// like it.
struct RequestDetailView: View {
    @ObservedObject var requests: Requests
    @Environment(\.sectionNavigator) private var navigator
    @Environment(\.isNarrow) private var narrow
    let title: SeerrTitle

    @State private var details: SeerrDetails?
    @State private var ratings: SeerrRatings?
    @State private var recommended: [SeerrTitle] = []
    @State private var similar: [SeerrTitle] = []
    @State private var asking: Ask?
    /// The quality just asked for, until the page has loaded again and can
    /// say how that went.
    @State private var announcing: Bool?
    @State private var said: String?
    @State private var problem: String?
    @FocusState private var header: HeaderButton?

    /// The panel that asks: for which quality, and with which of a show's
    /// seasons ticked (nil for all that can be asked for).
    struct Ask: Identifiable {
        let in4K: Bool
        var seasons: Set<Int>? = nil
        var id: Bool { in4K }
    }

    private enum HeaderButton: Hashable { case main, fourK, library }

    private static let top = "request-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    Color.clear.frame(height: 0).id(Self.top)
                    // Seerr's own page, top to bottom: the header, then the
                    // overview with the facts in a box beside it. Each is one
                    // focus section, poster and box and all, so up from a
                    // card under either finds what's above it.
                    heading
                        .tvFocusSection()
                    overview
                        .tvFocusSection()
                    if !shownRequests.isEmpty { requestList }
                    if let client = requests.client {
                        if let cast = details?.cast.prefix(20), !cast.isEmpty {
                            Shelf(title: String(localized: "Cast"), accent: Theme.palette[3]) {
                                ForEach(cast) { SeerrCastCard(person: $0, client: client) }
                            }
                            // Sections, so a short shelf isn't stepped over.
                            .tvFocusSection()
                        }
                        if !recommended.isEmpty {
                            Shelf(title: String(localized: "Recommendations", comment: "Shelf of titles suggested for someone who liked this one"),
                                  accent: Theme.palette[2]) {
                                ForEach(recommended) { SeerrPosterCard(title: $0, client: client, width: RequestCard.posterWidth) }
                            }
                            .tvFocusSection()
                        }
                        if !similar.isEmpty {
                            Shelf(title: String(localized: "Similar Titles", comment: "Shelf of titles like this one"),
                                  accent: Theme.palette[1]) {
                                ForEach(similar) { SeerrPosterCard(title: $0, client: client, width: RequestCard.posterWidth) }
                            }
                            .tvFocusSection()
                        }
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.vertical, 48)
            }
            .pageSides()
            // Back up to the buttons brings the whole header back into view.
            .onChange(of: header) { _, now in
                guard now != nil else { return }
                withAnimation(.easeOut(duration: 0.3)) { proxy.scrollTo(Self.top, anchor: .top) }
            }
        }
        // The page opens on its first button, which is at the far end of
        // the header: left to itself, focus took the first card of the
        // cast, further down and nearer the left.
        .defaultFocus($header, .main)
        .background(alignment: .top) { backdrop }
        .requestsBackground()
        // Again whenever a request is made, answered or taken back.
        .task(id: requests.revision) { await load() }
        .fullScreenCover(item: $asking) { ask in
            RequestPanel(requests: requests, title: title, details: details, in4K: ask.in4K, preselected: ask.seasons) {
                // Onto the button that stays, before one that was pressed goes.
                header = .main
                said = nil
                problem = nil
                announcing = ask.in4K
                requests.asked()
            }
            .presentationBackground(.clear)
        }
    }

    // MARK: The header

    /// Poster, then where it stands, its name with the year and a line of
    /// particulars, and the buttons at the far end: on a phone, one under
    /// another down the middle.
    private var heading: some View {
        let poster = Color.clear
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay(RemoteImage(url: requests.client?.poster(details?.posterPath ?? title.posterPath)))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 24, y: 12)
        return Group {
            if narrow {
                VStack(spacing: 14) {
                    poster.frame(width: 128)
                    naming(centred: true)
                    actions
                }
                .frame(maxWidth: .infinity)
            } else {
                HStack(alignment: .bottom, spacing: 28) {
                    poster.frame(width: CGFloat(280).scaled)
                    naming(centred: false)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    actions
                }
            }
        }
    }

    private func naming(centred: Bool) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: 8) {
            if !badges.isEmpty {
                HStack(spacing: 10) {
                    ForEach(badges, id: \.prefix) { SeerrBadgeView(badge: $0.badge, prefix: $0.prefix) }
                }
            }
            // The year beside the name, lighter and smaller.
            (Text(details?.displayTitle ?? title.displayTitle)
                .font(.app(narrow ? 28 : 40, .bold))
             + Text(year.map { " (\($0))" } ?? "")
                .font(.app(narrow ? 20 : 28))
                .foregroundColor(.white.opacity(0.75)))
                .multilineTextAlignment(centred ? .center : .leading)
            attributes
            if let said { SettingsNote(said, tint: Theme.accent) }
            if let problem { SettingsNote(problem, tint: Theme.palette[1].0) }
        }
    }

    private var year: String? { details?.year ?? title.year }

    /// The age rating in a box, how long it runs, and its genres, with bars
    /// between as Seerr has them.
    private var attributes: some View {
        var parts: [String] = []
        if let runtime = details?.runtime, runtime > 0 {
            parts.append(Duration.seconds(runtime * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
        }
        if let genres = details?.genres.prefix(3), !genres.isEmpty { parts.append(genres.joined(separator: ", ")) }
        return HStack(spacing: 8) {
            if let rating = details?.certification {
                Text(rating)
                    .padding(.horizontal, CGFloat(6).scaled)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.5), lineWidth: 1))
                if !parts.isEmpty { Text(verbatim: "|") }
            }
            Text(parts.joined(separator: "  |  "))
                .lineLimit(1)
        }
        .font(.app(narrow ? 14 : 18))
        .foregroundStyle(.white.opacity(0.8))
    }

    // MARK: The overview

    /// What it's about on one side, and the facts of it in a box on the
    /// other; on a phone, the box underneath.
    private var overview: some View {
        let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                            : AnyLayout(HStackLayout(alignment: .top, spacing: 40))
        return layout {
            VStack(alignment: .leading, spacing: 12) {
                if let tagline = details?.tagline {
                    Text(tagline)
                        .font(.app(narrow ? 19 : 24))
                        .italic()
                        .foregroundStyle(.white.opacity(0.62))
                }
                if let words = details?.overview ?? title.overview, !words.isEmpty {
                    Text("Overview", comment: "Heading above a film or show's plot")
                        .font(.app(narrow ? 20 : 24, .bold))
                        .foregroundStyle(.white.opacity(0.85))
                    Text(words)
                        .font(.app(narrow ? 16 : 19))
                        .foregroundStyle(.white.opacity(0.66))
                        .lineLimit(narrow ? 10 : 7)
                }
                if !crew.isEmpty {
                    // Who made it, three to a line: what they did over who.
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .topLeading), count: narrow ? 2 : 3),
                              alignment: .leading, spacing: 16) {
                        ForEach(crew, id: \.name) { part in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(part.did)
                                    .font(.app(16, .bold))
                                    .foregroundStyle(.white.opacity(0.85))
                                Text(part.name)
                                    .font(.app(16))
                                    .foregroundStyle(.white.opacity(0.62))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .padding(.top, 10)
                }
                if let details, !seasons.isEmpty {
                    SeerrSeasonList(requests: requests, title: title, details: details, libraryID: libraryID,
                                    specials: specials, allows4K: allows4K) { asking = Ask(in4K: false, seasons: [$0]) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if !facts.isEmpty || !scores.isEmpty {
                factBox
                    .frame(width: narrow ? nil : CGFloat(440).scaled)
            }
        }
    }

    /// The directors of a film, or the creators of a show, each with what
    /// they did.
    private var crew: [(did: String, name: String)] {
        guard let details else { return [] }
        return details.directors.prefix(3).map { (String(localized: "Director"), $0) }
            + details.creators.prefix(3).map { (String(localized: "Creator"), $0) }
    }

    /// Seerr's box of facts: the scores across the top, then a line each,
    /// what it is on the left and the answer on the right.
    private var factBox: some View {
        VStack(spacing: 0) {
            if !scores.isEmpty {
                HStack(spacing: 18) {
                    ForEach(scores, id: \.0) { name, score in
                        HStack(spacing: 6) {
                            Text(verbatim: name).foregroundStyle(.white.opacity(0.6))
                            Text(verbatim: score).fontWeight(.semibold)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, CGFloat(11).scaled)
                if !facts.isEmpty { Divider().overlay(RequestCard.ring) }
            }
            ForEach(Array(facts.enumerated()), id: \.offset) { index, fact in
                HStack(alignment: .top, spacing: 12) {
                    Text(fact.0)
                        .foregroundStyle(.white.opacity(0.85))
                    Spacer(minLength: 8)
                    Text(fact.1)
                        .foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.trailing)
                }
                .padding(.horizontal, CGFloat(16).scaled)
                .padding(.vertical, CGFloat(9).scaled)
                if index < facts.count - 1 { Divider().overlay(RequestCard.ring) }
            }
        }
        .font(.app(16))
        .background(Theme.background.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(RequestCard.ring, lineWidth: 1))
    }

    /// As a title in the library has its own, and dimmed further: here the
    /// words sit right on the picture.
    private var backdrop: some View {
        RemoteImage(url: requests.client?.backdrop(details?.backdropPath ?? title.backdropPath))
            .frame(height: Theme.isPhone ? 560 : 880)
            .frame(maxWidth: .infinity)
            .padding(.trailing, -80)
            .clipped()
            .overlay(Theme.background.opacity(0.66))
            // A wash of the section's own colour over the picture too, so
            // the page is as plainly the Requests section's as the rest.
            .overlay(Theme.primary.0.opacity(0.24))
            #if os(tvOS)
            .overlay(alignment: .leading) {
                LinearGradient(colors: [Theme.background, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: 180)
            }
            #endif
            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                         .init(color: .black.opacity(0.7), location: 0.55),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
    }

    // MARK: What it is

    private var media: SeerrMedia? { details?.mediaInfo ?? title.mediaInfo }

    /// Where it stands, and where its 4K copy does if that's anywhere.
    private var badges: [(prefix: String?, badge: SeerrBadge)] {
        var badges: [(prefix: String?, badge: SeerrBadge)] = []
        if let badge = media?.availability().badge { badges.append((nil, badge)) }
        if let badge = media?.availability(in4K: true).badge { badges.append(("4K", badge)) }
        return badges
    }

    /// The scores Seerr shows across the top of its box: their makers'
    /// names need no translating.
    private var scores: [(String, String)] {
        var scores: [(String, String)] = []
        let percent = { (part: Double) in part.formatted(.percent.precision(.fractionLength(0))) }
        if let critics = ratings?.critics { scores.append(("RT", percent(Double(critics) / 100))) }
        if let imdb = ratings?.imdb, imdb > 0 { scores.append(("IMDb", imdb.formatted(.number.precision(.fractionLength(1))))) }
        if let score = details?.voteAverage ?? title.voteAverage, score > 0 { scores.append(("TMDB", percent(score / 10))) }
        return scores
    }

    /// When it came out, what language and country it's from, and who made
    /// it or where it's on: a line of the box each.
    private var facts: [(String, String)] {
        guard let details else { return [] }
        var rows: [(String, String)] = []
        if let day = details.releasedText {
            rows.append((title.isMovie ? String(localized: "Release Date", comment: "Label for the day a film came out")
                                       : String(localized: "First Aired", comment: "Label for the day a TV show was first on"), day))
        }
        if let code = details.originalLanguage, let language = Locale.current.localizedString(forLanguageCode: code) {
            rows.append((String(localized: "Original Language", comment: "Label for the language a film or show was made in"),
                         language.prefix(1).uppercased() + language.dropFirst()))
        }
        let countries = details.countries.prefix(3).compactMap { Locale.current.localizedString(forRegionCode: $0) }
        if !countries.isEmpty {
            rows.append((String(localized: "Production Country", comment: "Label for the country a film or show was made in"),
                         countries.joined(separator: "\n")))
        }
        if !details.makers.isEmpty {
            rows.append((title.isMovie ? String(localized: "Studio", comment: "Label for the company that made a film")
                                       : String(localized: "Network", comment: "Label for the channel or service a TV show is on"),
                         details.makers.prefix(3).joined(separator: "\n")))
        }
        return rows
    }

    /// The title in the library, when it (or some of it) is there.
    private var libraryID: String? {
        let there = media?.availability() ?? .unasked
        guard there == .available || there == .partlyAvailable || media?.availability(in4K: true) == .available else { return nil }
        return media?.jellyfinMediaId ?? media?.jellyfinMediaId4k
    }

    // MARK: Asking

    private var specials: Bool { requests.settings?.enableSpecialEpisodes == true }

    /// Whether Seerr takes 4K requests for this kind of title, from this viewer.
    private var allows4K: Bool {
        (title.isMovie ? requests.settings?.movie4kEnabled : requests.settings?.series4kEnabled) == true
            && requests.user?.requestsIn4K(movie: title.isMovie) == true
    }

    /// Whether there's anything of it left to ask for, in that quality.
    private func canAsk(in4K: Bool) -> Bool {
        let there = media?.availability(in4K: in4K) ?? .unasked
        if title.isMovie { return there == .unasked }
        // Before a show's seasons are known, one nobody has asked for has
        // all of them to ask for.
        guard let details else { return there == .unasked }
        return !details.askableSeasons(in4K: in4K, specials: specials).isEmpty
    }

    /// What the page's first button does. There always is one, whatever the
    /// title's standing: with nothing on the page to hold focus, it would go
    /// off to the menu, and a button taken away once it's pressed would send
    /// it there too.
    private enum Main {
        case ask
        /// The title is in the library: its id there.
        case open(String)
        /// Nothing to do but wait.
        case standing(SeerrBadge)
    }

    private var main: Main {
        if canAsk(in4K: false) { return .ask }
        if let libraryID { return .open(libraryID) }
        if let badge = media?.availability().badge { return .standing(badge) }
        return .ask
    }

    private var actions: some View {
        // Side by side, or one under another where a phone hasn't the width.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { buttons }
            VStack(spacing: 12) { buttons }
        }
        .fixedSize(horizontal: !narrow, vertical: false)
    }

    @ViewBuilder
    private var buttons: some View {
        let main = main
        Button {
            switch main {
            case .ask: asking = Ask(in4K: false)
            case .open(let id): navigator.showItem(id)
            case .standing: break
            }
        } label: {
            switch main {
            case .ask: Text("Request", comment: "Asks for a film or show to be added to the library")
            case .open: Text("Open in Library")
            case .standing(let badge): Label(badge.text, systemImage: badge.symbol)
            }
        }
        .buttonStyle(.pill(selected: { if case .standing = main { false } else { true } }()))
        .focused($header, equals: .main)

        if allows4K, canAsk(in4K: true) {
            Button(String(localized: "Request in 4K")) { asking = Ask(in4K: true) }
                .buttonStyle(.pill(selected: false))
                .focused($header, equals: .fourK)
        }
        // Beside asking for the rest of a show that's partly there.
        if case .ask = main, let libraryID {
            Button(String(localized: "Open in Library")) { navigator.showItem(libraryID) }
                .buttonStyle(.pill(selected: false))
                .focused($header, equals: .library)
        }
    }

    // MARK: Its requests

    /// The requests there are for it, the newest first: everyone's for
    /// someone who may see them, and otherwise the viewer's own. Ones that
    /// have long since arrived are kept for whoever manages requests, who
    /// may want them gone; to anyone else they'd only repeat the badge.
    private var shownRequests: [SeerrRequest] {
        guard let user = requests.user else { return [] }
        return (media?.requests ?? [])
            .filter { user.seesAllRequests || $0.requestedBy?.id == user.id }
            .filter { user.managesRequests || $0.badge.tone != .good }
            .sorted { $0.id > $1.id }
    }

    private var requestList: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Requests", comment: "Menu section and settings page: asking for titles through Seerr")
                .font(.app(20, .bold))
            ForEach(shownRequests) { request in
                let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                    : AnyLayout(HStackLayout(spacing: 16))
                layout {
                    SeerrBadgeView(badge: request.badge, prefix: request.is4k == true ? "4K" : nil)
                    Text([request.seasonsText, request.byline(naming: requests.user?.seesAllRequests == true)]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.app(17))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                    if !narrow { Spacer(minLength: 12) }
                    RequestActionButtons(request: request, requests: requests, settled: { _ in
                        // Its buttons are about to change or go.
                        header = .main
                        said = nil
                        problem = nil
                        try? await Task.sleep(for: .milliseconds(200))
                    }, failed: { problem = $0 })
                }
                .padding(.horizontal, CGFloat(20).scaled)
                .padding(.vertical, CGFloat(12).scaled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .frame(maxWidth: CGFloat(1200).scaled, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSection()
    }

    // MARK: A show's seasons

    private var seasons: [SeerrDetails.Season] {
        title.isMovie ? [] : details?.seasons(specials: specials) ?? []
    }

    // MARK: Loading

    private func load() async {
        guard let client = await requests.ready() else {
            problem = String(localized: "Seerr couldn't be reached.")
            return
        }
        if let fresh = try? await client.details(of: title) {
            details = fresh
        } else if details == nil {
            problem = String(localized: "Seerr couldn't be reached.")
        }
        if let in4K = announcing {
            announcing = nil
            // By the viewer's newest request for it, where that can be seen:
            // a show partly in the library stands as it did.
            let mine = (media?.requests ?? [])
                .filter { $0.requestedBy?.id == requests.user?.id && ($0.is4k == true) == in4K }
                .max { $0.id < $1.id }
            let waiting = mine?.waiting ?? (media?.availability(in4K: in4K) == .awaitingApproval)
            said = waiting ? String(localized: "Requested. It's waiting to be approved.")
                           : String(localized: "Requested. It will be in your library once it's ready.")
        }
        // The rest is the same however often the page loads.
        guard ratings == nil, recommended.isEmpty, similar.isEmpty else { return }
        async let scores = client.ratings(of: title)
        async let suggested = client.titles(.recommendations, to: title)
        async let alike = client.titles(.similar, to: title)
        ratings = await scores
        recommended = await suggested
        similar = await alike
    }
}

/// Someone in a film or show, as Seerr's cast row has them: a card the size
/// of a poster with their photograph in a round, their name and who they
/// play. Through to what else they've been in.
struct SeerrCastCard: View {
    let person: SeerrDetails.Credit
    let client: SeerrClient

    var body: some View {
        let width = RequestCard.posterWidth
        NavigationLink(value: RequestRoute.person(person.id)) {
            VStack(spacing: 6) {
                SeerrFace(url: client.face(person.profilePath), glyphSize: 44)
                    .frame(width: width * 0.72, height: width * 0.72)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(RequestCard.ring, lineWidth: 1))
                    .padding(.top, width * 0.09)
                    .padding(.bottom, width * 0.05)
                Text(person.name)
                    .font(.app(17, .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(person.character ?? " ")
                    .font(.app(14))
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(width: width, height: width * 1.5)
            .background(RequestCard.surface)
            .clipped()
            .keepsCardCorners()
        }
        .buttonStyle(.tvCard)
        .accessibilityLabel([person.name, person.character].compactMap { $0 }.joined(separator: ", "))
    }
}

/// A photograph of someone, or the outline of a person where there's none.
struct SeerrFace: View {
    let url: URL?
    let glyphSize: CGFloat

    var body: some View {
        if let url {
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

/// Someone's page: who they are, and everything they've been in to ask for.
struct RequestPersonView: View {
    @ObservedObject var requests: Requests
    @Environment(\.isNarrow) private var narrow
    let id: Int

    @State private var person: SeerrPerson?
    @State private var titles: [SeerrTitle] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: RequestCard.posterWidth), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                HStack(alignment: .top, spacing: narrow ? 16 : 32) {
                    SeerrFace(url: requests.client?.face(person?.profilePath), glyphSize: 50)
                        .frame(width: narrow ? 96 : CGFloat(180).scaled, height: narrow ? 96 : CGFloat(180).scaled)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 12) {
                        Text(person?.name ?? "")
                            .font(.app(narrow ? 28 : 36, .bold))
                        if let biography = person?.biography, !biography.isEmpty {
                            ExpandableText(text: biography, lines: 4)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                // Photograph and all, so up from under it finds the biography.
                .tvFocusSection()
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 240)
                        .focusable()
                } else if titles.isEmpty {
                    Text("Nothing here yet.")
                        .foregroundStyle(Theme.textSecondary)
                        .focusable()
                } else if let client = requests.client {
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(titles) { SeerrPosterCard(title: $0, client: client) }
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 48)
        }
        .pageSides()
        .requestsBackground()
        // Again once something of theirs has been asked for, so its card says so.
        .task(id: requests.revision) { await load() }
    }

    private func load() async {
        guard let client = await requests.ready() else {
            loaded = true
            return
        }
        async let who = client.person(id)
        async let credits = client.titles(with: id)
        if let found = await who { person = found }
        titles = await credits
        loaded = true
    }
}
