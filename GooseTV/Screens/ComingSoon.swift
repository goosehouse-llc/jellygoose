import SwiftUI

/// When an episode still to come airs, as a day. The server keeps an
/// episode's air date as a day at midnight in UTC, which read as a moment
/// lands on the day before west of Greenwich: so it's read as the day it says.
enum AirDay {
    static func of(_ item: BaseItem) -> Date? { Date(serverDay: item.premiereDate) }

    private static let near: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// "Today", "Tomorrow" as the device says them, then "Thu 23 Oct".
    static func short(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) { return near.string(from: date) }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// A day's heading: "Today", "Tomorrow", then "Thursday 23 October".
    static func heading(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) { return near.string(from: date) }
        return date.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }

    /// What a card of one says under its show's name: "Thu 23 Oct · S2 · E3".
    static func caption(_ item: BaseItem) -> String? {
        let day = of(item).map(short)
        let parts = [day, item.episodeLabel].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Still to come: not on the server yet, or airing later than now.
    static func isComing(_ item: BaseItem, now: Date = Date()) -> Bool {
        if item.isUpcoming { return true }
        guard let day = of(item) else { return false }
        return day >= Calendar.current.startOfDay(for: now) && item.locationType != "FileSystem"
    }
}

/// The episodes of the library's shows still to air, a day at a time.
struct ComingSoonView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.sectionNavigator) private var navigator
    @State private var episodes: [BaseItem] = []
    @State private var loaded = false

    /// Each day with its episodes, soonest first.
    private var days: [(day: Date, episodes: [BaseItem])] {
        let grouped = Dictionary(grouping: episodes) { AirDay.of($0) ?? .distantFuture }
        return grouped.keys.sorted().map { day in
            (day, grouped[day, default: []].sorted { ($0.seriesName ?? "", $0.indexNumber ?? 0) < ($1.seriesName ?? "", $1.indexNumber ?? 0) })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                ShelfHeader(title: String(localized: "Coming Soon", comment: "Home row and page: episodes of the library's shows still to air"),
                            eyebrow: String(localized: "Your shows"), accent: Theme.palette[2])
                if !loaded {
                    ProgressView()
                        .frame(maxWidth: .infinity, minHeight: 300)
                        .focusable()
                } else if episodes.isEmpty {
                    Text("Nothing coming up. The server lists the episodes still to air of shows it has, where its information about them says when.",
                         comment: "Coming Soon, with nothing in it")
                        .foregroundStyle(Theme.textSecondary)
                        .padding(.top, 20)
                        .focusable()
                } else {
                    ForEach(days, id: \.day) { day in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(day.day == .distantFuture ? String(localized: "Date Unknown", comment: "Heading in a library of recordings: the ones nothing says the date of")
                                                           : AirDay.heading(day.day))
                                .font(.app(Theme.isPhone ? 18 : 22, .bold))
                                .foregroundStyle(Theme.palette[2].1)
                                .padding(.leading, 14)
                            ForEach(day.episodes) { episode in
                                row(episode)
                            }
                        }
                        .tvFocusSection()
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, Theme.isPhone ? 20 : 48)
        }
        .pageSides()
        .task {
            guard let client = app.client else { return }
            episodes = ((try? await client.upcomingEpisodes(limit: 200)) ?? []).filter { AirDay.isComing($0) }
            loaded = true
        }
    }

    /// An episode: its picture, its show, which one it is and what it's
    /// called. Chosen, its show's page.
    private func row(_ episode: BaseItem) -> some View {
        Button {
            navigator.showItem(episode.seriesId ?? episode.id)
        } label: {
            HStack(spacing: CGFloat(18).scaled) {
                RemoteImage(url: app.client?.imageURL(for: episode, type: "Primary", maxWidth: 400)
                                ?? app.client?.imageURL(for: episode, type: "Backdrop", maxWidth: 400))
                    .frame(width: CGFloat(Theme.isPhone ? 96 : 160).scaled, height: CGFloat(Theme.isPhone ? 54 : 90).scaled)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(episode.seriesName ?? episode.displayTitle)
                        .font(.app(Theme.isPhone ? 17 : 21, .semibold))
                        .lineLimit(1)
                    Text([episode.episodeLabel, episode.seriesName == nil ? nil : episode.displayTitle]
                            .compactMap { $0 }.joined(separator: " · "))
                        .font(.app(Theme.isPhone ? 14 : 17))
                        .opacity(0.65)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TrackRowStyle())
        .accessibilityLabel([episode.seriesName, episode.episodeLabel, episode.displayTitle].compactMap { $0 }.joined(separator: ", "))
    }
}
