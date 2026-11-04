import SwiftUI

/// When an episode on television first aired, for the guide to say of a
/// rerun. Listings like Tunarr's carry it, and the server drops it on the
/// way in; the episode in the library has it, found by its series and its
/// season and number, or else its title. Asked the once for each.
@MainActor
final class LiveAirDates {
    static let shared = LiveAirDates()

    /// A show's series in the library by the show's name, nil where there's none.
    private var series: [String: String?] = [:]
    /// The episodes of a series, of a season or all of them.
    private var episodes: [String: [BaseItem]] = [:]
    private var found: [String: Date?] = [:]
    private var asking: [String: Task<Date?, Never>] = [:]
    /// Counts the accounts: an answer for the one before isn't kept.
    private var generation = 0

    /// Already known, for a description drawn again: no line arriving late.
    func known(_ program: LiveProgram) -> Date? {
        if let first = program.firstAired { return Self.earlier(first, than: program) }
        return found[Self.key(program)] ?? nil
    }

    func airDate(of program: LiveProgram, with client: (any MediaServer)?) async -> Date? {
        if let first = program.firstAired { return Self.earlier(first, than: program) }
        // Something with episodes, which a library would have.
        guard let client, program.season != nil || program.episode != nil || program.episodeTitle?.isEmpty == false else { return nil }
        let key = Self.key(program)
        if let answer = found[key] { return answer }
        if let task = asking[key] { return await task.value }
        let mine = generation
        let task = Task { await self.look(program, with: client, generation: mine) }
        asking[key] = task
        let answer = await task.value
        guard mine == generation, !task.isCancelled else { return nil }
        asking[key] = nil
        found[key] = .some(answer)
        return answer
    }

    private func look(_ program: LiveProgram, with client: any MediaServer, generation mine: Int) async -> Date? {
        let name = program.name.lowercased()
        let seriesId: String?
        if let known = series[name] {
            seriesId = known
        } else {
            seriesId = await client.libraryTitle(named: program.name, film: false)?.id
            guard mine == generation else { return nil }
            series[name] = .some(seriesId)
        }
        guard let seriesId else { return nil }
        let shelf = "\(seriesId)|\(program.season.map(String.init) ?? "all")"
        let all: [BaseItem]
        if let known = episodes[shelf] {
            all = known
        } else {
            all = await client.libraryEpisodes(of: seriesId, season: program.season)
            guard mine == generation else { return nil }
            episodes[shelf] = all
        }
        let byNumber = program.episode.flatMap { number in
            all.first { $0.indexNumber == number && (program.season == nil || $0.parentIndexNumber == program.season) }
        }
        let byTitle = program.episodeTitle.flatMap { title in
            all.first { $0.name?.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        }
        return (byNumber ?? byTitle)?.premiereDay.flatMap { Self.earlier($0, than: program) }
    }

    /// Only a date before the day it's on says anything: the news airs today.
    private static func earlier(_ date: Date, than program: LiveProgram) -> Date? {
        date < Calendar.current.startOfDay(for: program.start) ? date : nil
    }

    private static func key(_ program: LiveProgram) -> String {
        [program.name.lowercased(), program.season.map(String.init) ?? "", program.episode.map(String.init) ?? "",
         program.episodeTitle?.lowercased() ?? ""].joined(separator: "|")
    }

    /// Another account or another server: another library.
    func forget() {
        generation += 1
        asking.values.forEach { $0.cancel() }
        asking = [:]
        series = [:]
        episodes = [:]
        found = [:]
    }
}

/// What a programme is about, as the guide and the full screen say it:
/// which season and episode it is, and for a rerun when it first aired,
/// ahead of the rest.
struct LiveProgrammeAbout: View {
    @Environment(\.appState) private var app
    let program: LiveProgram
    let font: Font
    let color: Color
    let lines: Int
    @State private var aired: Date?

    init(program: LiveProgram, font: Font, color: Color, lines: Int) {
        self.program = program
        self.font = font
        self.color = color
        self.lines = lines
        _aired = State(initialValue: LiveAirDates.shared.known(program))
    }

    var body: some View {
        let about = program.overview.flatMap { $0.isEmpty ? nil : $0 }
        Group {
            if aired != nil || about != nil || numbered != nil {
                Text(words(about))
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(lines)
            }
        }
        .task(id: program.id) {
            aired = LiveAirDates.shared.known(program)
            aired = await LiveAirDates.shared.airDate(of: program, with: app?.client)
        }
    }

    /// "S3 · E20", where the listings number it.
    private var numbered: String? {
        guard let season = program.season, let episode = program.episode else { return nil }
        return String(localized: "S\(season) · E\(episode)", comment: "Episode label: S = season number, E = episode number")
    }

    private func words(_ about: String?) -> AttributedString {
        let when = aired.map {
            String(localized: "Aired \($0.formatted(date: .abbreviated, time: .omitted))",
                   comment: "Live TV: when a rerun's episode was first shown; the placeholder is a date like Feb 20, 1988")
        }
        let lead = [numbered, when].compactMap { $0 }
        guard !lead.isEmpty else { return AttributedString(about ?? "") }
        var head = AttributedString(lead.joined(separator: " · "))
        head.font = font.bold()
        guard let about else { return head }
        return head + AttributedString(" · " + about)
    }
}
