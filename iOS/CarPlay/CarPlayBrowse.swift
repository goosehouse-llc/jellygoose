import Foundation

/// The arithmetic of fitting a library to a car's lists.
///
/// A car shows so many rows in a list and drops the rest, and a long list is
/// no way to find a film from the driver's seat. So a letter with many titles
/// is offered in stretches, named as a dictionary's pages are by the words
/// they run between ("Sa – Sc", "Se – Sh"), each short enough to take in, and
/// a list that can't be cut that way (a season, the favourites) is turned a
/// screenful at a time.
///
/// Nothing here touches CarPlay: it's kept apart so it can be worked through
/// without a car.
enum CarPlayBrowse {
    /// As many titles as a list is given where there's a choice: more than
    /// this is a scroll, and the car may allow far more.
    static let comfortable = 40

    /// `range` of a letter's titles cut into stretches. `limit` is the most
    /// titles one list can show and `fanout` the most stretches one can offer.
    ///
    /// The stretches come out near enough equal, each begun where the titles'
    /// second letter changes when that's close by, so "Sc" isn't left in two
    /// of them. With more titles than `fanout` lists can hold, the stretches
    /// are longer than a list, and each is cut again when it's opened.
    static func stretches(of range: Range<Int>, names: [String], limit: Int, fanout: Int) -> [Range<Int>] {
        let limit = max(1, limit)
        // Short of the limit, so a cut can move either way and still fit.
        let longest = max(1, min(comfortable, limit * 4 / 5))
        guard range.count > limit else { return [range] }
        let pieces = min(max(fanout, 2), (range.count + longest - 1) / longest)
        let size = (range.count + pieces - 1) / pieces
        let reach = size / 4
        var starts = [range.lowerBound]
        for piece in 1..<pieces {
            let ideal = range.lowerBound + piece * size
            guard let previous = starts.last, ideal > previous, ideal < range.upperBound else { break }
            let near = [0] + (1...max(reach, 1)).flatMap { [$0, -$0] }
            let cut = near.lazy.map { ideal + $0 }.first { at in
                at > previous && at < range.upperBound && names.indices.contains(at)
                    && (size > limit || at - previous <= limit)
                    && opening(names[at - 1]) != opening(names[at])
            } ?? ideal
            starts.append(cut)
        }
        return zip(starts, starts.dropFirst() + [range.upperBound]).map { $0..<$1 }
    }

    /// What a stretch is called: the least of its first title's name that
    /// tells it from the title before, to the least of its last that tells
    /// it from the one after. "Sa – Sc"; "Star T – Star W" where it takes
    /// that much; "St" alone when both come to the same.
    static func label(for range: Range<Int>, names: [String]) -> String {
        guard !range.isEmpty, names.indices.contains(range.lowerBound),
              names.indices.contains(range.upperBound - 1) else { return "" }
        let before = range.lowerBound > 0 ? names[range.lowerBound - 1] : nil
        let after = range.upperBound < names.count ? names[range.upperBound] : nil
        let first = guideWord(names[range.lowerBound], against: before)
        var last = guideWord(names[range.upperBound - 1], against: after)
        // "Shel – Sh" says less than "Shel – Shu": enough of the last name to
        // tell it from the first as well.
        if first.count > last.count, first.lowercased().hasPrefix(last.lowercased()) {
            let fuller = guideWord(names[range.upperBound - 1], against: names[range.lowerBound])
            if fuller.count > last.count { last = fuller }
        }
        return first.caseInsensitiveCompare(last) == .orderedSame ? first : "\(first) – \(last)"
    }

    /// The start of `name`, two letters or as many more as it takes to differ
    /// from `other` (up to twenty: two films of one name stay as they are).
    static func guideWord(_ name: String, against other: String?) -> String {
        let letters = Array(name)
        guard letters.count > 2 else { return name }
        let others = Array((other ?? "").lowercased())
        var length = 2
        while length < min(letters.count, 20),
              others.count >= length, String(letters[..<length]).lowercased() == String(others[..<length]) {
            length += 1
        }
        // Not ending on the gap between two words, nor a letter or two short
        // of the end of one ("Short Circui").
        while length < letters.count, letters[length - 1] == " " { length += 1 }
        if length > 2, let end = letters[length...].firstIndex(of: " ") ?? Optional(letters.count), end - length <= 2 {
            length = end
        }
        // "Star Trek IV:" reads better without what follows the name's first part.
        let word = String(letters[..<length]).trimmingCharacters(in: CharacterSet(charactersIn: " :,-–"))
        guard !word.isEmpty else { return name }
        return word.prefix(1).uppercased() + word.dropFirst()
    }

    /// A title as it's filed, for a stretch's name: its own name from the word
    /// the server sorts it by, which leaves "The" off "The Taking of Pelham"
    /// and keeps "Se7en" as it's written (the server's own sorting name has
    /// its numbers padded out, and is all in small letters).
    static func filedName(name: String, sortName: String?) -> String {
        guard let sortName else { return name }
        let lead = String(sortName.prefix { $0.isLetter })
        guard !lead.isEmpty, !name.lowercased().hasPrefix(lead.lowercased()) else { return name }
        // The word's first appearance at the start of a word.
        var search = name.startIndex..<name.endIndex
        while let found = name.range(of: lead, options: .caseInsensitive, range: search) {
            if found.lowerBound == name.startIndex || name[name.index(before: found.lowerBound)] == " " {
                return String(name[found.lowerBound...])
            }
            search = found.upperBound..<name.endIndex
        }
        return name
    }

    /// The first two letters, as stretches are told apart.
    private static func opening(_ name: String) -> String {
        String(name.lowercased().prefix(2))
    }

    /// A long list a screenful at a time: which of its `count` things a screen
    /// starting at `start` shows, when the car's list holds `room` rows and
    /// two of them may be needed for moving on and back. Everything, when it
    /// all fits.
    static func screenful(from start: Int, of count: Int, room: Int) -> Range<Int> {
        guard count > room else { return 0..<count }
        let each = max(1, room - 2)
        let from = min(max(0, start), max(0, count - 1))
        return from..<min(from + each, count)
    }

    /// The letters a library is filed under, grouped to fit `room` rows when
    /// there are more letters than that: "A – C", "D – F".
    static func letterGroups(_ letters: [String], room: Int) -> [[String]] {
        guard letters.count > room, room > 0 else { return letters.map { [$0] } }
        let size = (letters.count + room - 1) / room
        return stride(from: 0, to: letters.count, by: size).map { Array(letters[$0..<min($0 + size, letters.count)]) }
    }
}
