import SwiftUI

/// The sizes of the Requests screens' cards, in Seerr's own proportions and
/// larger than the library's posters: these are for looking through a few at
/// a time, not for finding one of hundreds.
enum RequestCard {
    #if os(tvOS)
    static let posterWidth: CGFloat = 260
    /// A genre's, studio's or network's card: twice as wide as it's tall.
    static let wide = CGSize(width: 400, height: 200)
    /// A request's card: its particulars beside its poster.
    static let request = CGSize(width: 540, height: 264)
    #else
    static let posterWidth: CGFloat = Theme.isPhone ? 150 : 180
    static let wide = Theme.isPhone ? CGSize(width: 224, height: 128) : CGSize(width: 288, height: 144)
    static let request = Theme.isPhone ? CGSize(width: 288, height: 156) : CGSize(width: 384, height: 200)
    #endif

    /// A card's own colour where it has no picture: the scheme's surface, a
    /// little see-through over the wallpaper, as Seerr's grey cards are.
    static var surface: Color { Theme.surface.opacity(0.9) }
    /// The hairline Seerr rings its cards and boxes with.
    static let ring = Color.white.opacity(0.14)
}

/// A genre, as Seerr's Discover cards one: its name over a picture from a
/// title of it, washed in the genre's two colours. Through to what there is
/// of it.
struct SeerrGenreCard: View {
    let genre: SeerrGenre
    /// Films, or shows.
    let movies: Bool
    let client: SeerrClient

    var body: some View {
        NavigationLink(value: RequestRoute.browse(movies ? .movieGenre(genre.id, genre.name) : .showGenre(genre.id, genre.name))) {
            ZStack {
                RemoteImage(url: client.art(of: genre))
                RequestCard.surface.opacity(0.3)
                Text(genre.name)
                    .font(.app(Theme.isPhone ? 24 : 30, .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .shadow(color: .black.opacity(0.35), radius: 5, y: 1)
                    .padding(.horizontal, 16)
            }
            .frame(width: RequestCard.wide.width, height: RequestCard.wide.height)
            .clipped()
            .keepsCardCorners()
        }
        .buttonStyle(.tvCard)
        .accessibilityLabel(genre.name)
    }
}

/// A studio or a network, as Seerr's Discover cards them: its logo in white
/// on a dark card. Through to what it has made, or what's on it.
struct SeerrCompanyCard: View {
    let company: SeerrCompany
    /// A film studio; otherwise a television network.
    let studio: Bool
    let client: SeerrClient

    var body: some View {
        NavigationLink(value: RequestRoute.browse(studio ? .studio(company.id, company.name) : .network(company.id, company.name))) {
            ZStack {
                RequestCard.surface
                // Darker towards the foot, as Seerr's are.
                LinearGradient(colors: [.clear, .black.opacity(0.28)], startPoint: .center, endPoint: .bottom)
                SeerrLogo(url: client.logo(company.logo), name: company.name)
                    .padding(RequestCard.wide.height * 0.22)
            }
            .frame(width: RequestCard.wide.width, height: RequestCard.wide.height)
            .clipped()
            .keepsCardCorners()
        }
        .buttonStyle(.tvCard)
        .accessibilityLabel(company.name)
    }
}

/// A request, as Seerr's Recent Requests cards one: the title's backdrop
/// under its year, name, who asked, which seasons and where it stands, with
/// the poster at the side. Through to the title's page.
struct SeerrRequestCard: View {
    let entry: RequestEntry
    let client: SeerrClient
    /// Whether to say who asked: not where every request is the viewer's own.
    let naming: Bool

    var body: some View {
        let size = RequestCard.request
        let pad = size.height * 0.1
        NavigationLink(value: entry.title) {
            HStack(alignment: .top, spacing: pad) {
                VStack(alignment: .leading, spacing: 5) {
                    if let year = entry.title.year {
                        Text(year)
                            .font(.app(14, .medium))
                    }
                    Text(entry.title.displayTitle)
                        .font(.app(21, .bold))
                        .lineLimit(2)
                    if naming, let name = entry.request.requestedBy?.displayName {
                        Label(name, systemImage: "person.crop.circle.fill")
                            .font(.app(15, .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    if let seasons = entry.request.seasonsText {
                        Text(seasons)
                            .font(.app(15))
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    SeerrBadgeView(badge: entry.request.badge, prefix: entry.request.is4k == true ? "4K" : nil)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

                Color.clear
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay(RemoteImage(url: client.poster(entry.title.posterPath)))
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .padding(pad)
            .frame(width: size.width, height: size.height)
            .background {
                // The backdrop, darkening across to where the words are read.
                RemoteImage(url: client.still(entry.title.backdropPath))
                    .overlay(LinearGradient(stops: [.init(color: Theme.background.opacity(0.47), location: 0),
                                                    .init(color: Theme.background, location: 0.75)],
                                            startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .clipped()
            .keepsCardCorners()
        }
        .buttonStyle(.tvCard)
        .accessibilityLabel([entry.title.displayTitle, entry.title.year, entry.request.seasonsText,
                             naming ? entry.request.requestedBy?.displayName : nil, entry.request.badge.text]
            .compactMap { $0 }.joined(separator: ", "))
    }
}

/// "MOVIE" or "SERIES", as Seerr marks the corner of every poster: blue for
/// a film, purple for a show.
struct SeerrTypePill: View {
    let movie: Bool

    var body: some View {
        let tint = movie ? Color(red: 37 / 255, green: 99 / 255, blue: 235 / 255)
                         : Color(red: 147 / 255, green: 51 / 255, blue: 234 / 255)
        Text(movie ? String(localized: "Movie") : String(localized: "Series"))
            .textCase(.uppercase)
            .font(.app(12, .semibold))
            .kerning(0.8)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, CGFloat(9).scaled)
            .padding(.vertical, CGFloat(3).scaled)
            .background(tint.opacity(0.85), in: Capsule())
            .overlay(Capsule().stroke(tint, lineWidth: 1))
    }
}

/// Where a title stands, as Seerr marks the other corner: a small round
/// badge in the standing's colour.
struct SeerrStatusDot: View {
    let badge: SeerrBadge

    var body: some View {
        let side = CGFloat(26).scaled
        Image(systemName: badge.mark)
            .font(.app(12, .heavy))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(badge.tint.opacity(0.85), in: Circle())
            .overlay(Circle().stroke(badge.tint, lineWidth: 1))
            .shadow(color: .black.opacity(0.35), radius: 3, y: 1)
    }
}

extension SeerrBadge {
    /// Seerr's own: green for what's there, indigo for what's on its way,
    /// amber for what waits on someone, red for what went wrong.
    var tint: Color {
        switch tone {
        case .good: .green
        case .working: .indigo
        case .waiting: .orange
        case .bad: .red
        }
    }
}

/// A logo, whole within the room it's given; the name in its place until it
/// has come, and if it never does.
private struct SeerrLogo: View {
    let url: URL?
    let name: String
    @State private var image: UIImage?

    init(url: URL?, name: String) {
        self.url = url
        self.name = name
        _image = State(initialValue: ImagePipeline.cached(url))
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Text(name)
                    .font(.app(22, .bold))
                    .foregroundStyle(.white.opacity(0.85))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: url) {
            guard image == nil, let url, let loaded = await ImagePipeline.load(url), !Task.isCancelled else { return }
            image = loaded
        }
    }
}

/// What a genre, a studio or a network has to ask for, the most popular
/// first: a page of it at a time, more as the end comes into sight.
struct RequestBrowseView: View {
    @ObservedObject var requests: Requests
    let browse: SeerrBrowse

    @State private var titles: [SeerrTitle] = []
    /// How many pages are listed, and how many there are.
    @State private var page = 0
    @State private var pages = 1
    @State private var loaded = false
    @State private var fetching = false
    @State private var problem: String?

    private let columns = [GridItem(.adaptive(minimum: RequestCard.posterWidth), spacing: 24)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ShelfHeader(title: browse.name, eyebrow: kind,
                            accent: browse.movies == nil ? Theme.palette[1] : browse.movies == true ? Theme.palette[2] : Theme.palette[3])
                if let problem { SettingsNote(problem, tint: Theme.palette[1].0) }
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .focusable()
                } else if titles.isEmpty, problem == nil {
                    Text("Nothing here yet.")
                        .foregroundStyle(Theme.textSecondary)
                        .focusable()
                }
                if let client = requests.client {
                    // Clear of the heading, which a focused card's lift reaches.
                    LazyVGrid(columns: columns, spacing: 32) {
                        ForEach(titles) { SeerrPosterCard(title: $0, client: client) }
                        if loaded, page < pages {
                            // In sight at the foot of what's listed: time for
                            // the next page. A new one each time, so one still
                            // in sight afterwards asks again.
                            ProgressView()
                                .frame(maxWidth: .infinity, minHeight: 120)
                                .id("more-\(page)")
                                .onAppear { Task { await more() } }
                        }
                    }
                    .padding(.top, 14)
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 48)
        }
        .pageSides()
        .requestsBackground()
        // Again once something here has been asked for, so its card says so.
        .task(id: requests.revision) { await load() }
    }

    /// Said small above the name, which alone doesn't tell a genre of films
    /// from one of shows. One of Discover's rows names itself.
    private var kind: String? {
        switch browse {
        case .shelf: nil
        case .movieGenre: String(localized: "Movie Genres", comment: "Shelf of the genres of films")
        case .showGenre: String(localized: "Show Genres", comment: "Shelf of the genres of TV shows")
        case .studio: String(localized: "Studios", comment: "Shelf of film studios")
        case .network: String(localized: "Networks", comment: "Shelf of television networks and streaming services")
        }
    }

    /// The pages listed so far, afresh: the first time that's the first page.
    private func load() async {
        guard let client = await requests.ready() else {
            problem = String(localized: "Seerr couldn't be reached.")
            loaded = true
            return
        }
        fetching = true
        defer { fetching = false }
        var listed: [SeerrTitle] = []
        var seen = Set<String>()
        var count = pages
        var reached = 0
        for number in 1...max(page, 1) {
            guard let next = try? await client.titles(in: browse, page: number) else {
                if number == 1 { problem = String(localized: "Seerr couldn't be reached.") }
                break
            }
            // The same title can turn up on two pages as the order shifts.
            listed += next.titles.filter { seen.insert($0.id).inserted }
            count = next.pages
            reached = number
            if Task.isCancelled { return }
        }
        if !listed.isEmpty {
            titles = listed
            pages = count
            // As far as it got: a page that failed part-way is the next one
            // asked for, not one counted as listed.
            page = max(reached, 1)
            problem = nil
        }
        loaded = true
    }

    private func more() async {
        guard loaded, !fetching, page < pages, let client = await requests.ready() else { return }
        fetching = true
        defer { fetching = false }
        guard let next = try? await client.titles(in: browse, page: page + 1) else { return }
        let have = Set(titles.map(\.id))
        titles += next.titles.filter { !have.contains($0.id) }
        pages = next.titles.isEmpty ? page : next.pages
        page += 1
    }
}

/// The Requests section's wallpaper, for a page of it on an iPhone or iPad.
/// On the Apple TV pages are see-through and the wallpaper lies behind them
/// all (see `MainTabView`); here each page is opaque, so each carries it.
/// Not when the section is set to look as the rest of the app does.
private struct RequestsBackground: ViewModifier {
    @EnvironmentObject private var app: AppState

    func body(content: Content) -> some View {
        #if !os(tvOS)
        content.background {
            if app.requestsScheme != .same {
                RequestsWallpaper(theme: app.shownTheme).ignoresSafeArea()
            }
        }
        #else
        content
        #endif
    }
}

extension View {
    func requestsBackground() -> some View { modifier(RequestsBackground()) }
}
