import Foundation

/// A television channel the server can tune: one of an HDHomeRun's, or a line
/// of an IPTV list. The tuners are the server's. The app asks it for a
/// channel and is handed a stream, which the server keeps a tuner on until
/// it's told the stream is done with.
struct LiveChannel: Identifiable, Equatable {
    let id: String
    let name: String
    /// As the tuner numbers it: "7.1" over the air, "104" on cable.
    let number: String?
    var isFavorite: Bool
    /// The station's logo, where the server has one.
    let imageTag: String?
    /// What's on, where the server has a guide for the channel. Plenty of
    /// channels have none: a tuner with no listings set up, a station the
    /// listings leave out.
    var now: LiveProgram?
}

extension LiveChannel {
    /// Whether the channel is named for this programme: a channel that
    /// carries the one show all day (as the made-up channels of a server's
    /// own library do), on which the show's name in every square of the
    /// guide says nothing the channel hasn't. "Golden Girls" is named for
    /// "The Golden Girls", and "Parks and Rec" for "Parks and Recreation".
    func isNamed(for program: LiveProgram) -> Bool {
        func plain(_ name: String) -> String {
            var words = name.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            if words.hasPrefix("the ") { words.removeFirst(4) }
            return String(String.UnicodeScalarView(words.unicodeScalars.filter(CharacterSet.alphanumerics.contains)))
        }
        let channel = plain(name), show = plain(program.name)
        guard channel.count >= 3, show.count >= 3 else { return false }
        if channel == show { return true }
        // One the beginning of the other, where there's enough of it to
        // mean the same thing: "Parks and Rec". Not a station whose name
        // its programmes happen to begin with ("PBS NewsHour" on PBS,
        // "History's Greatest Mysteries" on History).
        let (short, long) = channel.count < show.count ? (channel, show) : (show, channel)
        return short.count >= 8 && long.hasPrefix(short)
    }
}

/// One programme in the guide.
struct LiveProgram: Identifiable, Equatable {
    let id: String
    /// The channel it's on.
    let channelId: String?
    let name: String
    let episodeTitle: String?
    let overview: String?
    let start: Date
    let end: Date
    let isMovie: Bool
    let isNews: Bool
    let isSports: Bool
    let isKids: Bool
    /// An episode of something, by the listings: one they give a number or
    /// a name of its own.
    var isSeries = false
    /// What it's rated, where the listings say ("TV-PG").
    var rating: String?
    /// Which season and episode of its series, where the listings number it.
    var season: Int?
    var episode: Int?
    /// When it was first shown, where the listings say and the server kept it.
    var firstAired: Date?
    /// The server's recording of this showing, where one is set (or under
    /// way), and of the series it's an episode of. What each is cancelled by.
    var timerId: String?
    var seriesTimerId: String?

    /// Whether this showing is to be recorded, or is being. A showing of a
    /// series set to record isn't always: the server passes over one it
    /// takes for a repeat of another, one it has already, and one that was
    /// called off, and says so by giving it no recording of its own.
    var isSetToRecord: Bool { timerId != nil }

    /// Whether it can be set to record each time it comes round, not this
    /// showing alone: anything with a name but a film. Not only what the
    /// listings mark an episode: the evening news is no episode of anything
    /// by them, nor is a quiz or a talk show whose episodes they don't
    /// number, and those are what's wanted night after night. The server
    /// keeps such a recording by the programme's name. Where the listings
    /// can't tell one showing of it from the next, the server takes them
    /// for the same thing shown again, and records the first of them it
    /// can see each time it reads the listings: one a night for a
    /// programme that's on once a night, which is what's asked of it.
    var comesRound: Bool { isSeries || (!isMovie && !name.isEmpty) }

    /// How far through it is, 0 to 1.
    func fraction(at moment: Date = Date()) -> Double {
        let length = end.timeIntervalSince(start)
        guard length > 0 else { return 0 }
        return min(max(moment.timeIntervalSince(start) / length, 0), 1)
    }

    func isOn(at moment: Date = Date()) -> Bool { start <= moment && moment < end }
}

/// A showing a search of the listings turned up: the programme, the channel
/// it's on as the listings name it, and its picture.
struct LiveListing: Identifiable, Equatable {
    var program: LiveProgram
    let channelName: String?
    let channelNumber: String?
    /// The tag of its picture, where the listings came with one.
    let imageTag: String?

    var id: String { program.id }
    /// "9.1 · WFTV".
    var channelLine: String { [channelNumber, channelName].compactMap { $0 }.joined(separator: " · ") }
}

/// A channel tuned: where its stream is, and what the server knows it by,
/// which is what it has to be told to let the tuner go.
struct LiveStream: Equatable {
    let channelId: String
    let url: URL
    let liveStreamId: String?
    let mediaSourceId: String?
    let playSessionId: String?
    /// The station's own stream, as broadcast, or the server's conversion of
    /// it (asked for when the quality limit in Settings is under what the
    /// station sends).
    let isDirect: Bool
}

/// A recording the server has set: one showing of a programme, to come or
/// under way.
struct LiveTimer: Identifiable, Equatable {
    let id: String
    let name: String
    let episodeTitle: String?
    let channelName: String?
    let start: Date
    let end: Date
    /// The series recording it comes of, where it wasn't set by itself.
    let seriesTimerId: String?
    /// Being recorded now.
    let isRecording: Bool
    /// The channel it's recorded from.
    var channelId: String? = nil
}

/// A series the server is set to record every episode of.
struct LiveSeriesTimer: Identifiable, Equatable {
    let id: String
    let name: String
    /// The channel it's recorded from; nil where it's any channel.
    let channelName: String?
    /// The channel it was set on, whether or not it's kept to.
    var ownChannel: String?
    var options = LiveSeriesOptions()
}

/// What the server's DVR goes by in recording a series: which of its
/// episodes, from where, when, and how many are kept.
struct LiveSeriesOptions: Equatable {
    /// Episodes not shown before, and not every repeat.
    var newOnly = false
    var anyChannel = false
    /// Whenever it's on, and not only around the time it was set at.
    var anyTime = true
    /// How many are kept, the oldest going as new ones come; 0 for all.
    var keepUpTo = 0
}

/// What the server is told about a stream being watched.
enum LiveEvent { case started, playing, stopped }

/// The kinds of programme the guide marks, which the channel list can be
/// narrowed to: the channels showing one now.
enum LiveGenre: String, CaseIterable {
    case news, sports, movies, kids

    func has(_ program: LiveProgram) -> Bool {
        switch self {
        case .news: program.isNews
        case .sports: program.isSports
        case .movies: program.isMovie
        case .kids: program.isKids
        }
    }
}

// MARK: - As the server sends them

struct LiveChannelsResult: Decodable {
    let items: [LiveChannelDTO]
    let totalRecordCount: Int?
}

struct LiveChannelDTO: Decodable {
    let id: String
    let name: String?
    let channelNumber: String?
    let number: String?
    let userData: UserData?
    let imageTags: ImageTags?
    let currentProgram: LiveProgramDTO?

    var channel: LiveChannel {
        LiveChannel(id: id, name: name ?? "", number: channelNumber ?? number,
                    isFavorite: userData?.isFavorite ?? false,
                    imageTag: imageTags?["Primary"], now: currentProgram?.program)
    }
}

struct LiveProgramsResult: Decodable {
    let items: [LiveProgramDTO]
}

struct LiveProgramDTO: Decodable {
    let id: String
    let channelId: String?
    let name: String?
    let episodeTitle: String?
    let overview: String?
    let startDate: String?
    let endDate: String?
    let isMovie: Bool?
    let isNews: Bool?
    let isSports: Bool?
    let isKids: Bool?
    let isSeries: Bool?
    let officialRating: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let premiereDate: String?
    let timerId: String?
    let seriesTimerId: String?
    /// Its own picture, where the listings came with one.
    let imageTags: ImageTags?
    /// The channel it's on, by name and number: sent with a programme
    /// found by searching, not with the guide's.
    let channelName: String?
    let channelNumber: String?

    var listing: LiveListing? {
        program.map { LiveListing(program: $0, channelName: channelName, channelNumber: channelNumber, imageTag: imageTags?["Primary"]) }
    }

    /// Nil for one with no times, which can't be placed.
    var program: LiveProgram? {
        guard let start = LiveDate.parse(startDate), let end = LiveDate.parse(endDate), end > start else { return nil }
        return LiveProgram(id: id, channelId: channelId, name: name ?? "", episodeTitle: episodeTitle, overview: overview,
                           start: start, end: end, isMovie: isMovie ?? false, isNews: isNews ?? false,
                           isSports: isSports ?? false, isKids: isKids ?? false, isSeries: isSeries ?? false,
                           rating: officialRating, season: parentIndexNumber, episode: indexNumber,
                           firstAired: Date(serverDay: premiereDate), timerId: timerId, seriesTimerId: seriesTimerId)
    }
}

struct LiveTimersResult: Decodable {
    let items: [LiveTimerDTO]
}

struct LiveTimerDTO: Decodable {
    let id: String
    let name: String?
    let channelName: String?
    let startDate: String?
    let endDate: String?
    let status: String?
    let seriesTimerId: String?
    let channelId: String?
    let programInfo: LiveProgramDTO?

    /// Nil for one with no times, and for one that's over or was called
    /// off: the server keeps a cancelled episode of a series on its list,
    /// so as not to set it again.
    var timer: LiveTimer? {
        guard let start = LiveDate.parse(startDate), let end = LiveDate.parse(endDate),
              status == nil || status == "New" || status == "InProgress" else { return nil }
        return LiveTimer(id: id, name: name ?? programInfo?.name ?? "", episodeTitle: programInfo?.episodeTitle,
                         channelName: channelName, start: start, end: end, seriesTimerId: seriesTimerId,
                         isRecording: status == "InProgress", channelId: channelId)
    }
}

struct LiveSeriesTimersResult: Decodable {
    let items: [LiveSeriesTimerDTO]
}

struct LiveSeriesTimerDTO: Decodable {
    let id: String
    let name: String?
    let channelName: String?
    let recordAnyChannel: Bool?
    let recordAnyTime: Bool?
    let recordNewOnly: Bool?
    let keepUpTo: Int?

    var timer: LiveSeriesTimer {
        LiveSeriesTimer(id: id, name: name ?? "", channelName: recordAnyChannel == true ? nil : channelName,
                        ownChannel: channelName,
                        options: LiveSeriesOptions(newOnly: recordNewOnly ?? false, anyChannel: recordAnyChannel ?? false,
                                                   anyTime: recordAnyTime ?? true, keepUpTo: keepUpTo ?? 0))
    }
}

/// The server's moments to the fraction of a second it writes ("2026-10-14T
/// 18:30:20.415056Z"), and a moment as it takes one: watching together goes
/// by tenths, where a listing goes by minutes.
enum ServerTime {
    private static let whole: ISO8601DateFormatter = {
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime]
        return reader
    }()

    static func parse(_ text: String?) -> Date? {
        guard var text, text.count >= 20 else { return nil }
        if text.hasSuffix("Z") { text.removeLast() }
        let parts = text.split(separator: ".", maxSplits: 1)
        guard let base = whole.date(from: String(parts[0]) + "Z") else { return nil }
        guard parts.count == 2, let fraction = Double("0." + parts[1].prefix(7)) else { return base }
        return base.addingTimeInterval(fraction)
    }

    static func write(_ date: Date) -> String {
        let seconds = date.timeIntervalSince1970
        let base = whole.string(from: Date(timeIntervalSince1970: seconds.rounded(.down)))
        let fraction = Int((seconds - seconds.rounded(.down)) * 1000)
        return base.dropLast() + String(format: ".%03dZ", fraction)
    }
}

enum LiveDate {
    private static let reader: ISO8601DateFormatter = {
        let reader = ISO8601DateFormatter()
        reader.formatOptions = [.withInternetDateTime]
        return reader
    }()

    /// The server writes "2026-10-09T21:30:00.0000000Z": to the second is as
    /// fine as a listing gets, so the fraction is dropped rather than parsed.
    /// A moment as the server takes one in a request.
    static func write(_ date: Date) -> String { reader.string(from: date) }

    static func parse(_ text: String?) -> Date? {
        guard let text else { return nil }
        if text.count > 19, text.hasSuffix("Z"), text.dropFirst(19).first == "." {
            return reader.date(from: String(text.prefix(19)) + "Z")
        }
        return reader.date(from: text)
    }
}
