import SwiftUI
import WidgetKit

// The iPhone's and iPad's home screen and Lock Screen widgets: what's part
// way through, and the next episode of each show being watched. A separate
// process: the session comes from the keychain the app shares (SharedSession),
// as the Apple TV's Top Shelf has it, and a tap is a link the app opens.

/// The app's own colours, as its first scheme has them.
enum WidgetColours {
    static let violet = Color(red: 0.48, green: 0.27, blue: 0.90)
    static let blue = Color(red: 0.00, green: 0.56, blue: 0.86)
    static let background = Color(red: 0.05, green: 0.05, blue: 0.08)
    static var gradient: LinearGradient {
        LinearGradient(colors: [violet, blue], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

enum WatchingKind {
    case resume, nextUp

    var title: String {
        switch self {
        case .resume: String(localized: "Continue Watching")
        case .nextUp: String(localized: "Next Up")
        }
    }
}

/// One title on a widget: what it is, how far through, and its picture,
/// fetched with it (a widget can't load a picture while it's drawn).
struct WatchingCard: Identifiable {
    let id: String
    let title: String
    let detail: String?
    let progress: Double?
    let image: UIImage?
}

struct WatchingEntry: TimelineEntry {
    let date: Date
    let kind: WatchingKind
    let cards: [WatchingCard]
    /// Nobody signed in to the app.
    var signedOut = false

    /// For the widget gallery: made-up titles, part-way through for Continue
    /// Watching, not yet started for Next Up.
    static func sample(_ kind: WatchingKind) -> WatchingEntry {
        let started = kind == .resume
        return WatchingEntry(date: Date(), kind: kind, cards: [
            WatchingCard(id: "1", title: "Gooseflight", detail: "S1 · E2", progress: started ? 0.4 : nil, image: nil),
            WatchingCard(id: "2", title: "The Long Migration", detail: started ? "2021" : "S3 · E1", progress: started ? 0.7 : nil, image: nil),
            WatchingCard(id: "3", title: "Pond Life", detail: "S2 · E5", progress: started ? 0.2 : nil, image: nil),
            WatchingCard(id: "4", title: "Winter Wings", detail: started ? "2019" : "S1 · E8", progress: started ? 0.9 : nil, image: nil),
        ])
    }
}

struct WatchingProvider: TimelineProvider {
    let kind: WatchingKind

    func placeholder(in context: Context) -> WatchingEntry { .sample(kind) }

    func getSnapshot(in context: Context, completion: @escaping (WatchingEntry) -> Void) {
        if context.isPreview { return completion(.sample(kind)) }
        Task { completion(await load(Self.count(context.family))) }
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchingEntry>) -> Void) {
        Task {
            let entry = await load(Self.count(context.family))
            // The app asks for it again as soon as anything's watched; this is
            // for what changes elsewhere (another device, the TV).
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }

    private static func count(_ family: WidgetFamily) -> Int {
        switch family {
        case .systemMedium: 2
        case .systemLarge, .systemExtraLarge: 4
        default: 1
        }
    }

    private func load(_ count: Int) async -> WatchingEntry {
        guard let session = SharedSession.current() else {
            return WatchingEntry(date: Date(), kind: kind, cards: [], signedOut: true)
        }
        let client = session.client
        let hidden = session.hiddenNextUp
        let kind = kind
        // A server that's off is an empty widget, not one that waits.
        let items: [BaseItem] = await withinDeadline(10) {
            switch kind {
            case .resume: try? await client.resumeItems(limit: count)
            case .nextUp: (try? await client.nextUp(limit: count + hidden.count))?.filter { !hidden.contains($0.id) }
            }
        } ?? []
        let chosen = Array(items.prefix(count))
        let images = await withTaskGroup(of: (String, UIImage?).self) { group in
            for item in chosen {
                group.addTask { (item.id, await Self.picture(of: item, client: client)) }
            }
            var found: [String: UIImage] = [:]
            for await (id, image) in group { if let image { found[id] = image } }
            return found
        }
        let cards = chosen.map { item in
            WatchingCard(id: item.id, title: item.isEpisode ? (item.seriesName ?? item.displayTitle) : item.displayTitle,
                         detail: item.isEpisode ? [item.episodeLabel, item.displayTitle].compactMap { $0 }.joined(separator: " · ")
                                                : item.productionYear.map(String.init),
                         progress: item.userData?.playedPercentage.map { $0 / 100 },
                         image: images[item.id])
        }
        return WatchingEntry(date: Date(), kind: kind, cards: cards)
    }

    /// A wide picture: an episode's still, else the title's own wide one,
    /// made small enough for a widget to hold.
    private static func picture(of item: BaseItem, client: MediaBrowserClient) async -> UIImage? {
        let order = item.isEpisode ? ["Primary", "Thumb", "Backdrop"] : ["Thumb", "Backdrop", "Primary"]
        guard let url = order.lazy.compactMap({ client.imageURL(for: item, type: $0, maxWidth: 640) }).first,
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        return UIImage(data: data)?.preparingThumbnail(of: CGSize(width: 640, height: 360))
    }
}

// MARK: - Drawn

struct WatchingWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: WatchingEntry

    var body: some View {
        content
            .containerBackground(for: .widget) { background }
    }

    @ViewBuilder
    private var content: some View {
        if entry.signedOut {
            message(String(localized: "Open JellyGoose to sign in.", comment: "Widget: nobody is signed in to the app"))
        } else if entry.cards.isEmpty {
            message(entry.kind == .resume ? String(localized: "Nothing in progress.", comment: "Widget: nothing part-way through")
                                          : String(localized: "Nothing up next.", comment: "Widget: no next episodes"))
        } else {
            switch family {
            case .systemSmall: small(entry.cards[0])
            case .systemMedium: medium
            case .accessoryRectangular: lockScreen(entry.cards[0])
            default: large
            }
        }
    }

    @ViewBuilder
    private var background: some View {
        // A small one is its picture, edge to edge.
        if family == .systemSmall, let image = entry.cards.first?.image {
            // Shaded at the top for the heading, and at the foot for the title:
            // the shade is the widget's size, the picture filling in behind it.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.8), location: 0),
                .init(color: .black.opacity(0.45), location: 0.25),
                .init(color: .clear, location: 0.45),
                .init(color: .black.opacity(0.85), location: 1),
            ], startPoint: .top, endPoint: .bottom)
            .background {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
            .clipped()
        } else if family == .accessoryRectangular {
            Color.clear
        } else {
            WidgetColours.background
        }
    }

    private func message(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            eyebrow
            Spacer(minLength: 0)
            Text(text)
                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                .foregroundStyle(.white.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var eyebrow: some View {
        Text(entry.kind.title.uppercased())
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .kerning(1.2)
            .foregroundStyle(WidgetColours.gradient)
    }

    /// The heading over a picture: white, which reads on any picture.
    private var eyebrowOnPicture: some View {
        Text(entry.kind.title.uppercased())
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .kerning(1.2)
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3)
    }

    private func small(_ card: WatchingCard) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if card.image == nil { eyebrow } else { eyebrowOnPicture }
            Spacer(minLength: 0)
            Text(card.title)
                .font(.system(.headline, design: .rounded).weight(.bold))
                .foregroundStyle(.white)
                .lineLimit(2)
            if let detail = card.detail {
                Text(detail)
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
            if let progress = card.progress { bar(progress).padding(.top, 4) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .widgetURL(DeepLink.play(card.id))
    }

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            eyebrow
            HStack(alignment: .top, spacing: 12) {
                ForEach(entry.cards.prefix(2)) { card in
                    Link(destination: DeepLink.play(card.id)) {
                        VStack(alignment: .leading, spacing: 4) {
                            picture(card)
                            Text(card.title)
                                .font(.system(.caption, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            // Which episode, for a show.
                            if let detail = card.detail {
                                Text(detail)
                                    .font(.system(.caption2, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                if entry.cards.count == 1 { Color.clear.frame(maxWidth: .infinity) }
            }
        }
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 10) {
            eyebrow
            ForEach(entry.cards.prefix(4)) { card in
                Link(destination: DeepLink.play(card.id)) {
                    HStack(spacing: 12) {
                        picture(card)
                            .frame(width: 112)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.title)
                                .font(.system(.subheadline, design: .rounded).weight(.semibold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            if let detail = card.detail {
                                Text(detail)
                                    .font(.system(.caption, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.7))
                                    .lineLimit(2)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func lockScreen(_ card: WatchingCard) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(entry.kind.title.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .widgetAccentable()
            Text(card.title)
                .font(.system(.headline, design: .rounded))
                .lineLimit(1)
            if let detail = card.detail {
                Text(detail)
                    .font(.system(.caption, design: .rounded))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .widgetURL(DeepLink.play(card.id))
    }

    /// A card's 16:9 picture, with how far through along its foot.
    private func picture(_ card: WatchingCard) -> some View {
        Color.white.opacity(0.08)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                if let image = card.image {
                    Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "film").foregroundStyle(.white.opacity(0.3))
                }
            }
            .overlay(alignment: .bottom) {
                if let progress = card.progress { bar(progress).padding(6) }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func bar(_ progress: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.3))
                Capsule().fill(WidgetColours.gradient)
                    .frame(width: max(4, geometry.size.width * min(max(progress, 0), 1)))
            }
        }
        .frame(height: 4)
    }
}

struct ContinueWatchingWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ContinueWatching", provider: WatchingProvider(kind: .resume)) {
            WatchingWidgetView(entry: $0)
        }
        .configurationDisplayName(String(localized: "Continue Watching"))
        .description(String(localized: "What you're part-way through, to carry on with in a tap.",
                            comment: "Widget gallery: what the Continue Watching widget shows"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextUp", provider: WatchingProvider(kind: .nextUp)) {
            WatchingWidgetView(entry: $0)
        }
        .configurationDisplayName(String(localized: "Next Up"))
        .description(String(localized: "The next episode of each show you're watching.",
                            comment: "Widget gallery: what the Next Up widget shows"))
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .accessoryRectangular])
    }
}

@main
struct JellyGooseWidgets: WidgetBundle {
    var body: some Widget {
        ContinueWatchingWidget()
        NextUpWidget()
        DownloadLiveActivity()
    }
}
