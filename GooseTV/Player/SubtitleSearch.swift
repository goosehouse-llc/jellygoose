import Foundation

/// Finding a subtitle on the internet for what's playing. The server does the
/// looking and the fetching, through whichever providers it has (Open
/// Subtitles, usually), and keeps the file with the film, where every other
/// player and every later evening finds it too. The app asks, shows what came
/// back, and turns the one chosen on without starting the film again.
enum SubtitleSearch {
    /// The languages offered: the ones Settings has, less "any".
    static var languages: [SubtitleLanguage] { SubtitleLanguage.all.filter { !$0.code.isEmpty } }

    /// The language looked in first: the account's for subtitles, else the
    /// device's, else English.
    static func openingLanguage(_ preferences: UserPreferences?) -> SubtitleLanguage {
        let languages = languages
        if let code = preferences?.subtitleLanguage, let chosen = languages.first(where: { $0.code == code }) {
            return chosen
        }
        if let device = Locale.current.language.languageCode?.identifier,
           let own = languages.first(where: { $0.shortCode == device }) {
            return own
        }
        return languages.first { $0.code == "eng" } ?? languages[0]
    }

    /// What came back, with the ones timed to this very file first. Otherwise
    /// in the order the server gave, which is its provider's.
    static func ordered(_ results: [RemoteSubtitle]) -> [RemoteSubtitle] {
        results.filter { $0.isHashMatch == true } + results.filter { $0.isHashMatch != true }
    }

    enum Failure: LocalizedError {
        /// The server said yes and the film has no new subtitle: its provider
        /// refused (a day's allowance used up, most often), which the server
        /// keeps to its own log.
        case notFetched

        var errorDescription: String? {
            String(localized: "The server couldn't fetch that one.", comment: "Shown when a subtitle chosen from an internet search didn't arrive")
        }
    }

    /// Has the server fetch `subtitle` and waits for it to be listed among
    /// the film's streams, which it is once the server has looked at the film
    /// again: a second or two, usually.
    static func fetch(_ subtitle: RemoteSubtitle, in language: SubtitleLanguage, for item: BaseItem,
                      mediaSourceId: String?, client: any MediaServer) async throws -> FoundSubtitle {
        let target = target(for: item, mediaSourceId: mediaSourceId, on: client)
        // What's beside the film now, to tell the new one from. Not known,
        // every file there would pass for it: so nothing is sent for.
        guard let had = try? await client.item(id: target) else { throw Failure.notFetched }
        let before = client.subtitles(of: had, mediaSourceId: mediaSourceId).streams
        try await client.downloadRemoteSubtitle(subtitle.id, for: target)
        var latest: (streams: [MediaStream], files: [SubtitleFile], drawable: [Int: URL])?
        for attempt in 0..<18 {
            try await Task.sleep(for: .milliseconds(attempt < 4 ? 1000 : 1500))
            guard let fresh = try? await client.item(id: target) else { continue }
            let now = client.subtitles(of: fresh, mediaSourceId: mediaSourceId)
            latest = now
            if let new = newcomer(in: now.streams, since: before), let found = found(new, among: now) {
                return found
            }
        }
        // Nothing new, but the file may have taken the place of one that was
        // there: a second fetch in a language is saved under the first's name
        // by some servers. The one in that language is it, then.
        if let latest, !before.isEmpty,
           let replaced = latest.streams.last(where: { $0.isExternalTextSubtitle && $0.language == language.code }),
           before.contains(where: { $0.isExternalTextSubtitle && $0.path == replaced.path }),
           let found = found(replaced, among: latest) {
            return found
        }
        throw Failure.notFetched
    }

    /// What the server is asked about: the file that's playing. A film kept
    /// in more than one version has an item for each on Jellyfin, a version's
    /// id being its item's, and asked about the film the server looks for,
    /// and saves beside, the first of them whichever is on screen.
    static func target(for item: BaseItem, mediaSourceId: String?, on client: any MediaServer) -> String {
        guard client.flavor == .jellyfin, let mediaSourceId, mediaSourceId != item.id,
              mediaSourceId.count == 32, mediaSourceId.allSatisfy(\.isHexDigit) else { return item.id }
        return mediaSourceId
    }

    private static func found(_ stream: MediaStream,
                              among now: (streams: [MediaStream], files: [SubtitleFile], drawable: [Int: URL])) -> FoundSubtitle? {
        guard let index = stream.index, let file = now.files.first(where: { $0.index == index }) else { return nil }
        return FoundSubtitle(index: index, name: stream.trackName, file: file.url,
                             streams: now.streams, drawable: now.drawable)
    }

    /// The subtitle file that's beside the film now and wasn't before.
    static func newcomer(in now: [MediaStream], since before: [MediaStream]) -> MediaStream? {
        let had = before.filter(\.isExternalTextSubtitle), have = now.filter(\.isExternalTextSubtitle)
        let known = Set(had.compactMap(\.path))
        if let named = have.last(where: { stream in stream.path.map { !known.contains($0) } ?? false }) {
            return named
        }
        // A server that doesn't say where its files are: whichever of them
        // has no like among the ones that were there.
        guard have.count > had.count else { return nil }
        var unmatched = had.map(\.likeness)
        for stream in have {
            if let at = unmatched.firstIndex(of: stream.likeness) { unmatched.remove(at: at) } else { return stream }
        }
        return have.last
    }
}

private extension MediaStream {
    /// Enough to tell one subtitle file from another when the server doesn't
    /// say where they are.
    var likeness: String { [language, codec, title, displayTitle].map { $0 ?? "" }.joined(separator: "|") }
}

extension RemoteSubtitle {
    /// What it's called in the list: the release it was timed to, where the
    /// provider says.
    var listedName: String {
        if let name, !name.isEmpty { return name }
        return providerName ?? id
    }

    /// The line under its name: what tells one from another at a glance.
    var listedDetail: String {
        var parts: [String] = []
        if isHashMatch == true {
            parts.append(String(localized: "Matches this file", comment: "A subtitle found on the internet that was timed to exactly the file being played"))
        }
        if let format, !format.isEmpty { parts.append(format.uppercased()) }
        if hearingImpaired == true {
            parts.append(String(localized: "SDH", comment: "A subtitle for the deaf and hard of hearing, with sounds described. Use your language's usual short label"))
        }
        if onlyForeignParts {
            parts.append(String(localized: "Forced", comment: "A subtitle that only has the lines spoken in another language"))
        }
        if translatedByMachine {
            parts.append(String(localized: "Machine translated", comment: "A subtitle that was translated by software rather than a person"))
        }
        if let providerName, !providerName.isEmpty, name?.isEmpty == false { parts.append(providerName) }
        return parts.joined(separator: " · ")
    }

    /// How many times it's been fetched, written short: "↓ 12K".
    var listedDownloads: String? {
        guard let downloadCount, downloadCount > 0 else { return nil }
        return "↓ " + downloadCount.formatted(.number.notation(.compactName))
    }
}

extension Array where Element == MediaStream {
    /// Where each of `old`'s streams is in this list, by the server's
    /// numbers, for a film whose streams were numbered again when a file was
    /// put beside it. The streams inside the film keep their order; the files
    /// beside it are known by where they are.
    func renumbering(of old: [MediaStream]) -> [Int: Int] {
        var moved: [Int: Int] = [:]
        for stream in old {
            guard let was = stream.index else { continue }
            if stream.isExternal == true {
                if let path = stream.path, let now = first(where: { $0.isExternal == true && $0.path == path })?.index {
                    moved[was] = now
                }
            } else if let place = old.fileStream(forServerIndex: was), let now = self.stream(atFileStream: place)?.index {
                moved[was] = now
            }
        }
        return moved
    }
}
