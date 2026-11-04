import Foundation

/// When a recording was made, and how that's said: a library of recordings
/// is so many showings of the same few programmes, the news every night
/// under the one name, and only the day and the hour tell them apart.
enum Recorded {
    private static let lock = NSLock()
    private static var known: [String: Date] = [:]

    /// The server names a recording's file for the moment it began
    /// ("FOX 35 News at 10pm 2026_10_12_22_00_00.ts"), by its own clock,
    /// which in a house is this device's too. Nothing else it keeps says
    /// when that was: the date an item was added is when the recording
    /// ended, so failing the name it's that less how long the recording runs.
    private static let stamp: NSRegularExpression? = try? NSRegularExpression(pattern: #"(\d{4})_(\d{2})_(\d{2})_(\d{2})_(\d{2})_(\d{2})\.[A-Za-z0-9]+$"#)

    static func date(of item: BaseItem) -> Date? {
        let key = item.id + (item.dateLastMediaAdded ?? item.dateCreated ?? "")
        lock.lock()
        let cached = known[key]
        lock.unlock()
        if let cached { return cached }
        guard let date = reckon(item) else { return nil }
        lock.lock()
        if known.count > 4000 { known.removeAll() }
        known[key] = date
        lock.unlock()
        return date
    }

    private static func reckon(_ item: BaseItem) -> Date? {
        // A show: the newest of its recordings.
        if item.isSeries { return LiveDate.parse(item.dateLastMediaAdded).flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil } ?? LiveDate.parse(item.dateCreated) }
        if let start = started(item) { return start.date }
        guard let added = LiveDate.parse(item.dateCreated) else { return nil }
        return added.addingTimeInterval(-Double(item.runTimeTicks ?? 0) / 10_000_000)
    }

    /// When the server began recording it, as its file is named: nil for
    /// anything that isn't a recording the server made.
    static func stamped(_ item: BaseItem) -> Date? {
        guard let path = item.path, let stamp,
              let found = stamp.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)) else { return nil }
        let parts = (1...6).compactMap { Range(found.range(at: $0), in: path).flatMap { Int(path[$0]) } }
        guard parts.count == 6 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                          hour: parts[3], minute: parts[4], second: parts[5]))
    }

    /// When a recording began, and whether the hour is known. By its file's
    /// name, as the server names a recording of something the guide gave no
    /// episode number; one it did number ("… S2026E288.ts") is named for the
    /// episode, and the day comes from the server's air date for it, with
    /// the hour the server began it where that's the same day. Not a rerun's:
    /// its air date is the first showing's, years back, and the server
    /// having had it since a week or more after that says so.
    static func started(_ item: BaseItem) -> (date: Date, timed: Bool)? {
        if let date = stamped(item) { return (date, true) }
        guard let path = item.path?.lowercased(), path.hasSuffix(".ts"),
              let day = airDay(item.premiereDate) else { return nil }
        if let begun = LiveDate.parse(item.dateCreated) {
            if Calendar.current.isDate(begun, inSameDayAs: day) { return (begun, true) }
            if begun.timeIntervalSince(day) > 7 * 86_400 { return nil }
        }
        return (day, false)
    }

    /// The day in an air date, which the server gives as midnight UTC of the
    /// day it means: that day here, at noon.
    private static func airDay(_ text: String?) -> Date? {
        guard let text, text.count >= 10 else { return nil }
        let parts = text.prefix(10).split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }

    /// "Aired Wed, Oct 15, 10:00 PM": what a recording's details say in place
    /// of the year, which the server gives as the show's (2001 for the news),
    /// not the showing's. Nil for anything that isn't a recording.
    static func aired(_ item: BaseItem, now: Date = Date()) -> String? {
        guard let start = started(item) else { return nil }
        let date = start.date
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        let day = date.formatted(sameYear ? .dateTime.weekday(.abbreviated).month(.abbreviated).day()
                                          : .dateTime.month(.abbreviated).day().year())
        guard start.timed else {
            return String(localized: "Aired \(day)", comment: "A recording's details: the day it went out, where the hour isn't known, like Aired Fri, Oct 16")
        }
        let hour = date.formatted(date: .omitted, time: .shortened)
        return String(localized: "Aired \(day), \(hour)", comment: "A recording's details: the day and time it went out, like Aired Wed, Oct 15, 10:00 PM")
    }

    /// The heading a recording is filed under, as the Finder files things:
    /// today, yesterday, the week before and the month before, and by the
    /// month beyond that. With a number to tell one heading from the next.
    static func day(of date: Date?, now: Date = Date()) -> (key: Int, title: String) {
        guard let date else {
            return (.min, String(localized: "Date Unknown", comment: "Heading in a library of recordings: the ones nothing says the date of"))
        }
        let calendar = Calendar.current
        switch daysAgo(date, now) {
        // "Today" and "Yesterday", as the system says them in the viewer's language.
        case ...0: return (3, relative.string(from: date))
        case 1: return (2, relative.string(from: date))
        case 2...7: return (1, String(localized: "Previous 7 Days", comment: "Heading in a library of recordings: the ones made in the week before yesterday"))
        case 8...30: return (0, String(localized: "Previous 30 Days", comment: "Heading in a library of recordings: the ones made in the month before the last week"))
        default:
            let parts = calendar.dateComponents([.year, .month], from: date)
            let sameYear = parts.year == calendar.component(.year, from: now)
            return ((parts.year ?? 0) * 12 + (parts.month ?? 0) - 1_000_000,
                    date.formatted(sameYear ? .dateTime.month(.wide) : .dateTime.month(.wide).year()))
        }
    }

    private static let relative: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    private static func daysAgo(_ date: Date, _ now: Date) -> Int {
        let calendar = Calendar.current
        return calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
    }

    /// The line under a recording's name. The hour alone where its heading
    /// says the day; the day of the week with it for the week past; the
    /// date beyond that. With no headings (the list in some other order),
    /// today and yesterday are said too.
    static func note(for item: BaseItem, headed: Bool, now: Date = Date()) -> String? {
        guard let date = date(of: item) else { return nil }
        let hour = date.formatted(date: .omitted, time: .shortened)
        let days = daysAgo(date, now)
        let sameYear = Calendar.current.component(.year, from: date) == Calendar.current.component(.year, from: now)
        let day: String? = switch days {
        case ...1: headed ? nil : relative.string(from: date)
        case 2...7: date.formatted(.dateTime.weekday(.wide))
        default: date.formatted(sameYear ? .dateTime.weekday(.abbreviated).day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year())
        }
        return [day, hour].compactMap { $0 }.joined(separator: " · ")
    }
}
