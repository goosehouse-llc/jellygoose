import SwiftUI

/// Seerr's Discover, for a television: what's been asked for lately, what's
/// trending, popular and coming, a search, and the way into the list of
/// requests.
struct RequestsView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.isNarrow) private var narrow
    @ObservedObject var requests: Requests
    @Binding var path: NavigationPath

    /// Connecting to the Seerr the menu offered.
    @State private var connecting = false
    @State private var recent: [RequestEntry] = []
    @State private var shelves: [SeerrClient.Shelf: [SeerrTitle]] = [:]
    @State private var movieGenres: [SeerrGenre] = []
    @State private var showGenres: [SeerrGenre] = []
    @State private var loaded = false
    @State private var problem: String?

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    HStack(alignment: .center, spacing: 16) {
                        // Seerr's own mark where the page's name was: the
                        // page is Seerr's, laid out as Seerr lays it out, and
                        // says so the way Seerr does. (The menu's row and the
                        // settings page keep the name of what's done here.)
                        Image("SeerrLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(height: CGFloat(46).scaled)
                            .accessibilityLabel(Text(verbatim: "Seerr"))
                            .accessibilityAddTraits(.isHeader)
                        Spacer()
                        if requests.client != nil {
                            // Their pictures alone on a phone, where the
                            // words would run to a second line.
                            Button {
                                path.append(RequestRoute.all)
                            } label: {
                                if narrow {
                                    Label(listName, systemImage: "list.bullet").labelStyle(.iconOnly)
                                } else {
                                    Label(listName, systemImage: "list.bullet")
                                }
                            }
                            .buttonStyle(.pill(selected: false))
                            Button {
                                path.append(RequestRoute.search)
                            } label: {
                                if narrow {
                                    Label("Search", systemImage: "magnifyingglass").labelStyle(.iconOnly)
                                } else {
                                    Label("Search", systemImage: "magnifyingglass")
                                }
                            }
                            .buttonStyle(.pill(selected: false))
                        }
                    }
                    .tvFocusSection()

                    if requests.client == nil {
                        offer
                    } else if let problem {
                        SettingsNote(problem, tint: Theme.palette[1].0)
                    } else if !loaded {
                        ProgressView()
                            .frame(maxWidth: .infinity, minHeight: 300)
                            .focusable()
                    }
                    if let client = requests.client {
                        if !recent.isEmpty {
                            Shelf(title: requests.user?.seesAllRequests == true
                                  ? String(localized: "Recent Requests", comment: "Shelf of what everyone has asked for lately")
                                  : String(localized: "Your Requests", comment: "Shelf of the titles the viewer has asked for"),
                                  accent: Theme.palette[0]) {
                                ForEach(recent) { entry in
                                    SeerrRequestCard(entry: entry, client: client, naming: requests.user?.seesAllRequests == true)
                                }
                            }
                            // A section, so a shelf of one or two cards isn't
                            // stepped over from the far side of the screen.
                            .tvFocusSection()
                        }
                        // Discover's rows, in Seerr's own order.
                        ForEach(Row.allCases, id: \.self) { row($0, client: client) }
                    }
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.vertical, 48)
            }
            .pageSides()
            .requestsBackground()
            .navigationDestination(for: SeerrTitle.self) { RequestDetailView(requests: requests, title: $0) }
            .navigationDestination(for: RequestRoute.self) { route in
                switch route {
                case .search: RequestSearchView(requests: requests)
                case .all: RequestListView(requests: requests)
                case .person(let id): RequestPersonView(requests: requests, id: id)
                case .browse(let browse): RequestBrowseView(requests: requests, browse: browse)
                }
            }
            .sectionDestinations()
        }
        .sectionNavigation(path: $path, section: "requests")
        // Again whenever a request is made, answered or taken back.
        .task(id: requests.revision) { await load() }
    }

    /// What Seerr's Discover page is made of, top to bottom.
    private enum Row: CaseIterable {
        case trending, movies, movieGenres, upcomingMovies, studios, shows, showGenres, upcomingShows, networks
    }

    @ViewBuilder
    private func row(_ row: Row, client: SeerrClient) -> some View {
        switch row {
        case .trending: titles(.trending, client: client)
        case .movies: titles(.movies, client: client)
        case .upcomingMovies: titles(.upcomingMovies, client: client)
        case .shows: titles(.shows, client: client)
        case .upcomingShows: titles(.upcomingShows, client: client)
        case .movieGenres:
            genres(movieGenres, movies: true, client: client)
        case .showGenres:
            genres(showGenres, movies: false, client: client)
        case .studios:
            // Shown with the rest, not ahead of it: they need no loading.
            if loaded, !shelves.isEmpty {
                Shelf(title: String(localized: "Studios", comment: "Shelf of film studios"), accent: Theme.palette[2]) {
                    ForEach(SeerrCompany.studios) { SeerrCompanyCard(company: $0, studio: true, client: client) }
                }
                .tvFocusSection()
            }
        case .networks:
            if loaded, !shelves.isEmpty {
                Shelf(title: String(localized: "Networks", comment: "Shelf of television networks and streaming services"),
                      accent: Theme.palette[3]) {
                    ForEach(SeerrCompany.networks) { SeerrCompanyCard(company: $0, studio: false, client: client) }
                }
                .tvFocusSection()
            }
        }
    }

    @ViewBuilder
    private func titles(_ kind: SeerrClient.Shelf, client: SeerrClient) -> some View {
        if let titles = shelves[kind], !titles.isEmpty {
            // Its heading leads to the whole of it, as each of Seerr's does.
            Shelf(title: Self.name(of: kind), accent: Self.accent(of: kind),
                  seeAll: { path.append(RequestRoute.browse(.shelf(kind, Self.name(of: kind)))) }) {
                ForEach(titles) { SeerrPosterCard(title: $0, client: client, width: RequestCard.posterWidth) }
            }
            // A section, so a shelf isn't stepped over from further along
            // than it reaches.
            .tvFocusSection()
        }
    }

    @ViewBuilder
    private func genres(_ genres: [SeerrGenre], movies: Bool, client: SeerrClient) -> some View {
        if !genres.isEmpty {
            Shelf(title: movies ? String(localized: "Movie Genres", comment: "Shelf of the genres of films")
                                : String(localized: "Show Genres", comment: "Shelf of the genres of TV shows"),
                  accent: movies ? Theme.palette[2] : Theme.palette[3]) {
                ForEach(genres) { SeerrGenreCard(genre: $0, movies: movies, client: client) }
            }
            .tvFocusSection()
        }
    }

    /// For an account that hasn't connected yet, on a server with a Seerr
    /// beside it: what this is, and a button to connect. Nothing is signed
    /// in to until it's pressed.
    private var offer: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ask for films and shows your server doesn't have yet, through Seerr. You're signed in there with your \(app.serverFlavor.label) account, with no password to type.",
                 comment: "The placeholder is the server software's name, Jellyfin or Emby")
                .font(.app(19))
                .foregroundStyle(Theme.textSecondary)
            HStack(spacing: 16) {
                if let found = requests.offered {
                    Button(String(localized: "Connect to \(found.host ?? found.absoluteString)",
                                  comment: "The placeholder is the address where a Seerr was found")) {
                        connect(to: found)
                    }
                    .buttonStyle(.pill(selected: true))
                    Button(String(localized: "Not Now")) { requests.decline() }
                        .buttonStyle(.pill(selected: false))
                }
                if connecting { ProgressView() }
            }
            if let problem { SettingsNote(problem, tint: Theme.palette[1].0) }
        }
        .frame(maxWidth: CGFloat(900).scaled, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .tvFocusSection()
    }

    private func connect(to found: URL) {
        guard !connecting else { return }
        connecting = true
        problem = nil
        Task {
            defer { connecting = false }
            do {
                try await requests.connect(to: found.absoluteString)
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    /// The list of requests, named for whose it shows.
    private var listName: String {
        requests.user?.seesAllRequests == true
            ? String(localized: "All Requests", comment: "Opens the list of everyone's requests")
            : String(localized: "Your Requests", comment: "Shelf of the titles the viewer has asked for")
    }

    private static func name(of shelf: SeerrClient.Shelf) -> String {
        switch shelf {
        case .trending: String(localized: "Trending", comment: "Shelf of films and shows that are popular right now")
        case .movies: String(localized: "Popular Movies")
        case .upcomingMovies: String(localized: "Upcoming Movies", comment: "Shelf of films that aren't out yet")
        case .shows: String(localized: "Popular Shows")
        case .upcomingShows: String(localized: "Upcoming Shows", comment: "Shelf of TV shows that haven't started yet")
        }
    }

    private static func accent(of shelf: SeerrClient.Shelf) -> (Color, Color) {
        switch shelf {
        case .trending: Theme.palette[1]
        case .movies, .upcomingMovies: Theme.palette[2]
        case .shows, .upcomingShows: Theme.palette[3]
        }
    }

    private func load() async {
        guard let client = await requests.ready() else {
            problem = requests.client == nil ? nil : String(localized: "Seerr couldn't be reached.")
            loaded = true
            return
        }
        // Nothing to show yet, as just after connecting: the spinner again.
        if shelves.isEmpty { loaded = false }
        // The requests alongside the rest, which is the same for everyone.
        async let asked = Self.recent(from: client)
        async let films = client.genres(movies: true)
        async let series = client.genres(movies: false)
        await withTaskGroup(of: (SeerrClient.Shelf, [SeerrTitle]?).self) { group in
            for kind in SeerrClient.Shelf.allCases {
                group.addTask { (kind, try? await client.titles(kind)) }
            }
            for await (kind, titles) in group {
                if let titles { shelves[kind] = titles }
            }
        }
        recent = await asked
        // Kept if they don't come this time: they don't change.
        let (filmGenres, seriesGenres) = await (films, series)
        if !filmGenres.isEmpty { movieGenres = filmGenres }
        if !seriesGenres.isEmpty { showGenres = seriesGenres }
        problem = shelves.isEmpty ? String(localized: "Seerr couldn't be reached.") : nil
        loaded = true
    }

    /// The latest requests the viewer may see, each with its title.
    private static func recent(from client: SeerrClient) async -> [RequestEntry] {
        guard let latest = try? await client.requests() else { return [] }
        return await client.titled(latest.list).map { RequestEntry(request: $0.request, title: $0.title) }
    }
}

enum RequestRoute: Hashable {
    case search
    /// The list of requests.
    case all
    /// Someone in a film or show, by their number at The Movie Database.
    case person(Int)
    /// What a genre, a studio or a network has.
    case browse(SeerrBrowse)
}

/// A request with the title it's for: a request names its title only by
/// number, so the title is looked up.
struct RequestEntry: Identifiable {
    let request: SeerrRequest
    let title: SeerrTitle
    var id: Int { request.id }
}

/// A film or show's poster among things to ask for, cornered as Seerr's are:
/// which kind it is on one side, and on the other where it stands, if it's
/// in the library or asked for already.
struct SeerrPosterCard: View {
    let title: SeerrTitle
    let client: SeerrClient
    var width: CGFloat? = nil

    var body: some View {
        let standing = title.mediaInfo?.availability ?? .unasked
        VStack(alignment: .leading, spacing: 10) {
            NavigationLink(value: title) {
                ZStack(alignment: .top) {
                    Color.clear
                        .aspectRatio(2 / 3, contentMode: .fit)
                        .overlay(RemoteImage(url: client.poster(title.posterPath)))
                        .clipped()
                    HStack(alignment: .top) {
                        SeerrTypePill(movie: title.isMovie)
                        Spacer(minLength: 4)
                        if let badge = standing.badge { SeerrStatusDot(badge: badge) }
                    }
                    .padding(CGFloat(9).scaled)
                }
                .keepsCardCorners()
                .frame(width: width)
            }
            .buttonStyle(.tvCard)
            .accessibilityLabel([title.displayTitle, title.year, standing.label].compactMap { $0 }.joined(separator: ", "))
            // The year too: a search for "Dune" finds four of them.
            VStack(alignment: .leading, spacing: 2) {
                Text(title.displayTitle)
                    .font(.app(16))
                    .lineLimit(1)
                Text(title.year ?? " ")
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: width ?? .infinity, alignment: .leading)
        }
    }
}

/// A standing as Seerr badges it: a word or two on its colour.
struct SeerrBadgeView: View {
    let badge: SeerrBadge
    /// Said first, for a copy other than the usual one: "4K".
    var prefix: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: badge.symbol)
            Text([prefix, badge.text].compactMap { $0 }.joined(separator: " · "))
        }
        .font(.app(15, .semibold))
        .foregroundStyle(.white)
        .lineLimit(1)
        .padding(.horizontal, CGFloat(12).scaled)
        .padding(.vertical, CGFloat(5).scaled)
        .background(badge.tint.opacity(0.32), in: Capsule())
        .overlay(Capsule().stroke(badge.tint.opacity(0.8), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

/// Anything at The Movie Database, by name.
struct RequestSearchView: View {
    @ObservedObject var requests: Requests
    @State private var query = ""
    @State private var results: [SeerrTitle] = []
    @State private var searching: Task<Void, Never>?
    /// What was last looked for and answered: "No results" waits for it.
    @State private var answered = ""

    private let columns = [GridItem(.adaptive(minimum: RequestCard.posterWidth), spacing: 24)]

    var body: some View {
        ScrollView {
            if results.isEmpty && query.count >= 2 && answered == query {
                Text("No results for “\(query)”")
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 100)
            } else if let client = requests.client {
                LazyVGrid(columns: columns, spacing: 32) {
                    ForEach(results) { SeerrPosterCard(title: $0, client: client) }
                }
                .padding(.horizontal, Theme.pageMargin)
                .padding(.vertical, 48)
            }
        }
        .pageSides()
        .requestsBackground()
        #if os(iOS)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: Text("Something to ask for…", comment: "Placeholder in the search for titles to request"))
        #elseif os(macOS)
        // On the page: the Mac's window shows no title bar to hold it.
        .safeAreaInset(edge: .top, spacing: 0) {
            MacSearchField(text: $query, prompt: Text("Something to ask for…", comment: "Placeholder in the search for titles to request"))
        }
        #else
        .searchable(text: $query, prompt: Text("Something to ask for…", comment: "Placeholder in the search for titles to request"))
        #endif
        .onChange(of: query) { _, term in look(for: term, after: .milliseconds(350)) }
        // Again once something here has been asked for, so its card says so.
        .onChange(of: requests.revision) { _, _ in look(for: query, after: .zero) }
    }

    private func look(for term: String, after wait: Duration) {
        searching?.cancel()
        guard term.count >= 2 else {
            results = []
            return
        }
        searching = Task {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled, let client = await requests.ready() else { return }
            if let found = try? await client.search(term), !Task.isCancelled {
                results = found
                answered = term
            }
        }
    }
}

/// Settings, Requests: connecting the app to a Seerr, and leaving it.
struct RequestsSettingsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var requests: Requests

    /// A Seerr that answered, to offer: the one on the server's machine, or
    /// the one just left.
    @State private var found: URL?
    @State private var looked = false
    @State private var typing = false
    @State private var connecting = false
    @State private var connectedAt = Date.distantPast
    @State private var problem: String?
    @FocusState private var onMain: Bool

    private var connected: Bool { requests.client != nil }

    var body: some View {
        SettingsPage(title: String(localized: "Requests", comment: "Menu section and settings page: asking for titles through Seerr"),
                     accent: Theme.palette[0]) {
            Text("Ask for films and shows your server doesn't have yet, through Seerr. You're signed in there with your \(app.serverFlavor.label) account, with no password to type.",
                 comment: "The placeholder is the server software's name, Jellyfin or Emby")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)

            VStack(alignment: .leading, spacing: 18) {
                if let client = requests.client {
                    SettingsNote(String(localized: "Connected to \(client.base.host ?? client.base.absoluteString)",
                                        comment: "The placeholder is the address of the Seerr the app is connected to"),
                                 tint: Theme.accent)
                    if let name = requests.user?.displayName ?? requests.user?.jellyfinUsername ?? app.userName {
                        Text("Signed in as \(name)")
                            .font(.app(17))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                // One button to connect and to leave, so focus stays where it
                // is as one becomes the other: a focused button taken away
                // would send focus off to the menu.
                HStack(spacing: 18) {
                    Button(mainLabel) { main() }
                        .buttonStyle(.pill(selected: !connected))
                        .focused($onMain)
                    if connecting, !connected { ProgressView() }
                }
                // Kept until connecting is over, focus having left it by then.
                if found != nil, !connected || connecting {
                    Button(String(localized: "Enter Address…", comment: "Opens a field to type the Seerr's address")) { typing = true }
                        .buttonStyle(.pill(selected: false))
                }
                if looked, found == nil, !connected, problem == nil {
                    Text("No Seerr was found on your server's machine. If you run one somewhere else, enter its address.")
                        .font(.app(16))
                        .foregroundStyle(Theme.textSecondary)
                }
                if let problem { SettingsNote(problem, tint: Theme.palette[1].0) }
            }
            .tvFocusSection()

            scheme
        }
        .task(id: connected) {
            guard !connected, found == nil else { return }
            found = await requests.find()
            looked = true
        }
        .fullScreenCover(isPresented: $typing) {
            TextEntryPanel(title: String(localized: "Seerr Address"),
                           message: String(localized: "Where your Seerr is, like 192.168.1.10:5055."),
                           placeholder: "192.168.1.10:5055",
                           initial: found.map(Self.typed) ?? "") { address in
                connect(address)
            }
            .presentationBackground(.clear)
        }
    }

    /// What the Requests section wears. The scheme least like the app's own
    /// unless another is picked, or the app's own for someone who'd rather
    /// it didn't change.
    private var scheme: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Colour Scheme", comment: "Heading of the setting for the Requests section's colours")
                .font(.app(21, .semibold))
            Text("Requests wears colours of its own, so it doesn't look like your library.")
                .font(.app(15))
                .foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    choice(String(localized: "Automatic"), .contrasting)
                    choice(String(localized: "Same as the App", comment: "The Requests section keeps the app's own colour scheme"), .same)
                    ForEach(AppTheme.allCases) { choice($0.label, .fixed($0)) }
                }
                .padding(.vertical, 12)   // room for the focused chip's lift
                .padding(.horizontal, 6)
            }
        }
        .padding(.top, 18)
        // Up and down land on the row, not on whichever chip lines up.
        .tvFocusSection()
    }

    private func choice(_ name: String, _ scheme: RequestsScheme) -> some View {
        Button(name) { app.requestsScheme = scheme }
            .buttonStyle(.chip(active: app.requestsScheme == scheme))
    }

    /// An address as someone would type it: "192.168.1.10:5055".
    private static func typed(_ address: URL) -> String {
        guard address.scheme == "http", address.path.isEmpty, let host = address.host else { return address.absoluteString }
        return address.port.map { "\(host):\($0)" } ?? host
    }

    private var mainLabel: String {
        if connected { return String(localized: "Disconnect", comment: "Stops using this Seerr") }
        if let found {
            return String(localized: "Connect to \(found.host ?? found.absoluteString)",
                          comment: "The placeholder is the address where a Seerr was found")
        }
        return String(localized: "Enter Address…", comment: "Opens a field to type the Seerr's address")
    }

    private func main() {
        guard !connecting else { return }
        if let client = requests.client {
            // Not on a second press of the one that connected.
            guard Date().timeIntervalSince(connectedAt) > 1 else { return }
            found = client.base
            problem = nil
            requests.disconnect()
            app.requestsChanged()
        } else if let found {
            connect(found.absoluteString)
        } else {
            typing = true
        }
    }

    private func connect(_ address: String) {
        guard !connecting, !address.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        connecting = true
        problem = nil
        Task {
            do {
                try await requests.connect(to: address)
                app.requestsChanged()
                connectedAt = Date()
                // Onto the button that's staying, before the other one goes.
                onMain = true
                try? await Task.sleep(for: .milliseconds(250))
            } catch {
                problem = error.localizedDescription
            }
            connecting = false
        }
    }
}
