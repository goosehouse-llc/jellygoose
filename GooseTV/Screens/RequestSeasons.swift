import SwiftUI

/// A show's seasons as Seerr's page has them, newest first: each opens in
/// place to list its episodes, newest first too, each with when it aired, what
/// happens in it and a frame from it. Beside each, what Seerr doesn't say:
/// whether the library has that episode (and, on a device that keeps
/// downloads, whether it's downloaded here). One in the library opens there.
struct SeerrSeasonList: View {
    @ObservedObject var requests: Requests
    @Environment(\.sectionNavigator) private var navigator
    @Environment(\.isNarrow) private var narrow
    let title: SeerrTitle
    let details: SeerrDetails
    /// The show on the media server, where some of it is there.
    let libraryID: String?
    let specials: Bool
    let allows4K: Bool
    /// Asks for one season, in the panel that asks.
    let ask: (Int) -> Void

    @State private var open: Set<Int> = []
    @State private var contents: [Int: Contents] = [:]

    /// One season's episodes, once they've come.
    private struct Contents {
        /// Nil while they're on their way.
        var episodes: [SeerrEpisode]?
        var failed = false
        /// What the library has of it, by episode number. Nil where that
        /// can't be told: the show isn't on the media server.
        var library: [Int: BaseItem]?
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Seasons")
                .font(.app(narrow ? 20 : 24, .bold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.top, 14)
            ForEach(details.seasons(specials: specials).reversed(), id: \.seasonNumber) { season in
                seasonRow(season)
                if open.contains(season.seasonNumber) {
                    panel(for: season.seasonNumber)
                }
            }
        }
        #if DEBUG
        // GOOSETV_SEERR_SEASON=<number> opens that season as the page opens.
        .task {
            guard let number = ProcessInfo.processInfo.environment["GOOSETV_SEERR_SEASON"].flatMap(Int.init),
                  open.isEmpty, details.seasons(specials: specials).contains(where: { $0.seasonNumber == number }) else { return }
            open.insert(number)
            await load(number)
        }
        #endif
    }

    // MARK: A season

    private func seasonRow(_ season: SeerrDetails.Season) -> some View {
        let number = season.seasonNumber
        let standing = details.standing(ofSeason: number, in4K: false)
        let standing4K = allows4K ? details.standing(ofSeason: number, in4K: true) : nil
        let isOpen = open.contains(number)
        return Button {
            withAnimation(.easeOut(duration: 0.2)) {
                if isOpen { open.remove(number) } else { open.insert(number) }
            }
            if !isOpen, contents[number]?.episodes == nil { Task { await load(number) } }
        } label: {
            HStack(spacing: 12) {
                Text(season.name ?? String(localized: "Season \(number)"))
                if let episodes = season.episodeCount {
                    Text(episodes == 1 ? String(localized: "1 episode") : String(localized: "\(episodes) episodes"))
                        .font(.app(14, .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, CGFloat(10).scaled)
                        .padding(.vertical, CGFloat(2).scaled)
                        .background(.black.opacity(0.4), in: Capsule())
                }
                Spacer()
                if let badge = standing.badge { SeerrBadgeView(badge: badge) }
                if let badge = standing4K?.badge { SeerrBadgeView(badge: badge, prefix: "4K") }
                Image(systemName: "chevron.down")
                    .font(.app(15, .bold))
                    .foregroundStyle(.white.opacity(0.6))
                    .rotationEffect(.degrees(isOpen ? 180 : 0))
            }
            .font(.app(18, .medium))
            .padding(.horizontal, CGFloat(18).scaled)
            .padding(.vertical, CGFloat(11).scaled)
        }
        .buttonStyle(SettingsRowStyle())
    }

    /// Under an open season: how much of it the library has, a button to
    /// ask for it where nobody has, then its episodes.
    @ViewBuilder
    private func panel(for number: Int) -> some View {
        let content = contents[number]
        VStack(alignment: .leading, spacing: 10) {
            if let episodes = content?.episodes {
                if let summary = summary(of: episodes, library: content?.library) {
                    Text(summary)
                        .font(.app(16, .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                }
                if details.standing(ofSeason: number, in4K: false) == .unasked {
                    Button(String(localized: "Request Season \(number)")) { ask(number) }
                        .buttonStyle(.pill(selected: true))
                }
                if episodes.isEmpty {
                    Text("Episode list unavailable.", comment: "A season Seerr has no episodes listed for (Seerr's own words)")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.vertical, 8)
                        .focusable()
                }
                ForEach(episodes.reversed()) { episode in
                    episodeRow(episode, in: content?.library)
                }
            } else if content?.failed == true {
                HStack(spacing: 16) {
                    Text("Seerr couldn't be reached.")
                        .foregroundStyle(Theme.textSecondary)
                    Button(String(localized: "Try Again")) { Task { await load(number) } }
                        .buttonStyle(.pill(selected: false))
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
            }
        }
        .padding(.leading, narrow ? 8 : CGFloat(28).scaled)
        .padding(.vertical, 6)
    }

    /// "47 of 52 episodes in your library", where the library can be asked.
    private func summary(of episodes: [SeerrEpisode], library: [Int: BaseItem]?) -> String? {
        guard let library, episodes.count > 1 else { return nil }
        let have = episodes.filter { library[$0.episodeNumber] != nil }.count
        return have == episodes.count
            ? String(localized: "All \(have) episodes in your library", comment: "Under a season: the library has every episode of it")
            : String(localized: "\(have) of \(episodes.count) episodes in your library", comment: "Under a season: how many of its episodes the library has")
    }

    // MARK: An episode

    @ViewBuilder
    private func episodeRow(_ episode: SeerrEpisode, in library: [Int: BaseItem]?) -> some View {
        let item = library?[episode.episodeNumber]
        if let item {
            Button { navigator.showItem(item.id) } label: { episodeLabel(episode, library: library, item: item) }
                .buttonStyle(SettingsRowStyle())
        } else {
            #if os(tvOS)
            // Focusable all the same, or the remote couldn't scroll to it.
            Button {} label: { episodeLabel(episode, library: library, item: nil) }
                .buttonStyle(SettingsRowStyle())
            #else
            episodeLabel(episode, library: library, item: nil)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            #endif
        }
    }

    private func episodeLabel(_ episode: SeerrEpisode, library: [Int: BaseItem]?, item: BaseItem?) -> some View {
        HStack(alignment: .top, spacing: narrow ? 12 : 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: episode.name.map { "\(episode.episodeNumber) - \($0)" } ?? "\(episode.episodeNumber)")
                    .font(.app(narrow ? 16 : 18, .semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                // Onto a second line where there isn't the width.
                PillFlow(spacing: 8) { pills(episode, library: library, item: item) }
                if let overview = episode.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.app(narrow ? 14 : 15))
                        .foregroundStyle(.white.opacity(0.68))
                        .lineLimit(narrow ? 3 : 2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let still = requests.client?.still(episode.stillPath) {
                let width = narrow ? 104 : Self.stillWidth
                RemoteImage(url: still)
                    .frame(width: width, height: width * 9 / 16)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, CGFloat(16).scaled)
        .padding(.vertical, CGFloat(12).scaled)
        .accessibilityElement(children: .combine)
    }

    /// When it aired, as Seerr says it (and how long ago or until, within a
    /// week or so), then whether the library has it.
    @ViewBuilder
    private func pills(_ episode: SeerrEpisode, library: [Int: BaseItem]?, item: BaseItem?) -> some View {
        if let aired = episode.aired {
            DayPill(text: aired.formatted(Self.longDate))
            if let near = Self.nearby(aired) { DayPill(text: near) }
        }
        if item != nil {
            if let badge = SeerrAvailability.available.badge { SeerrBadgeView(badge: badge) }
            #if !os(tvOS)
            if let item, Downloads.shared.record(item.id)?.state == .done {
                SeerrBadgeView(badge: SeerrBadge(text: String(localized: "Downloaded"), symbol: "arrow.down.circle.fill", tone: .working))
            }
            #endif
        } else if library != nil, episode.hasAired {
            // Only where the library can be asked, and only for what's been shown.
            SeerrBadgeView(badge: SeerrBadge(text: String(localized: "Not in Library", comment: "An episode that has aired but isn't on the media server"),
                                             symbol: "xmark.circle.fill", tone: .bad))
        }
    }

    /// An episode's frame: smaller where the list shares the width with the
    /// facts beside it, as it does on an iPad.
    #if os(tvOS)
    private static let stillWidth: CGFloat = 240
    #else
    private static let stillWidth: CGFloat = 168
    #endif

    /// The day as Seerr writes it, "October 1, 2018", in the viewer's language.
    private static let longDate = Date.FormatStyle(date: .long, time: .omitted, timeZone: TimeZone(identifier: "UTC") ?? .current)

    /// "3 days ago", "tomorrow": for a day within eight of today, as Seerr
    /// adds beside the date.
    private static func nearby(_ day: Date) -> String? {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        guard let days = utc.dateComponents([.day], from: utc.startOfDay(for: .now), to: day).day, abs(days) <= 8 else { return nil }
        let say = RelativeDateTimeFormatter()
        say.dateTimeStyle = .named
        say.unitsStyle = .full
        // "Today", "In 7 days": each starts a badge of its own.
        say.formattingContext = .beginningOfSentence
        return say.localizedString(from: DateComponents(day: days))
    }

    // MARK: Loading

    private func load(_ number: Int) async {
        contents[number] = Contents()
        guard let client = await requests.ready() else {
            contents[number] = Contents(failed: true)
            return
        }
        async let season = try? client.season(number, of: title)
        let library: [Int: BaseItem]? = if let libraryID { await requests.libraryEpisodes(of: libraryID, season: number) } else { nil }
        guard let found = await season else {
            contents[number] = Contents(failed: true)
            return
        }
        contents[number] = Contents(episodes: found.episodes, library: library)
    }
}

/// A day, in Seerr's plain grey badge.
private struct DayPill: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.app(15, .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .lineLimit(1)
            .padding(.horizontal, CGFloat(12).scaled)
            .padding(.vertical, CGFloat(5).scaled)
            .background(.white.opacity(0.1), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.3), lineWidth: 1))
    }
}

/// Badges in a line, carried onto the next where they don't fit.
private struct PillFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(of: subviews, width: proposal.width ?? .infinity)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, $0.count - 1)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        var index = 0
        for row in rows(of: subviews, width: bounds.width) {
            var x = bounds.minX
            let height = row.map(\.height).max() ?? 0
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height + spacing
        }
    }

    private func rows(of subviews: Subviews, width: CGFloat) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var used: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, used + spacing + size.width > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows
    }
}
