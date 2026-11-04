import Foundation

/// What a viewer chose to hear and read in a show: kept for the show, so its
/// next episode (and any other, and the same one again) starts that way
/// instead of with the server's defaults. By language rather than by track
/// number: the episodes of a show number their tracks differently.
struct TrackChoice: Codable, Equatable {
    /// The audio's language, as the server gives it ("jpn"); nil keeps the
    /// server's choice.
    var audioLanguage: String?
    /// Its name too, which tells a commentary from the film in the same language.
    var audioTitle: String?
    /// Whether subtitles were on, and which.
    var subtitleOff = false
    var subtitleLanguage: String?
    var subtitleForced = false
    var subtitleTitle: String?
}

enum TrackMemory {
    static let key = "goosetv.trackMemory"
    /// The shows remembered, newest last; the oldest go beyond this many.
    static let most = 400

    private struct Entry: Codable {
        let show: String
        var choice: TrackChoice
    }

    private static func entries() -> [Entry] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return saved
    }

    private static func save(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(Array(entries.suffix(most))) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func choice(forShow show: String) -> TrackChoice? {
        entries().last { $0.show == show }?.choice
    }

    /// The tracks playing now in a show, chosen by the viewer: the audio as
    /// it is, and the subtitle (nil with `off` false leaves it unknown).
    static func remember(show: String, audio: MediaStream?, subtitle: MediaStream?, subtitleOff: Bool) {
        var choice = TrackChoice()
        choice.audioLanguage = audio?.language
        choice.audioTitle = audio?.title
        if subtitleOff {
            choice.subtitleOff = true
        } else if let subtitle {
            choice.subtitleLanguage = subtitle.language
            choice.subtitleForced = subtitle.isForced == true
            choice.subtitleTitle = subtitle.title
        } else if let kept = Self.choice(forShow: show) {
            // The subtitle couldn't be told: what was remembered of it stands.
            choice.subtitleOff = kept.subtitleOff
            choice.subtitleLanguage = kept.subtitleLanguage
            choice.subtitleForced = kept.subtitleForced
            choice.subtitleTitle = kept.subtitleTitle
        }
        guard choice.audioLanguage != nil || choice.subtitleOff || choice.subtitleLanguage != nil else { return }
        var all = entries().filter { $0.show != show }
        all.append(Entry(show: show, choice: choice))
        save(all)
    }

    /// The server's numbers for a remembered choice among an episode's
    /// streams; nil for either where nothing matches (the server's own
    /// default stays), and the subtitle `PlaybackContext.subtitlesOff` for off.
    static func indexes(for choice: TrackChoice, in streams: [MediaStream]) -> (audio: Int?, subtitle: Int?) {
        let audio = streams.filter { $0.type == "Audio" && $0.index != nil }
        let subtitles = streams.filter { $0.type == "Subtitle" && $0.index != nil }
        var wantedAudio: Int?
        if let language = choice.audioLanguage {
            let same = audio.filter { Language.same($0.language, language) }
            wantedAudio = (same.first { $0.title == choice.audioTitle } ?? same.first { $0.isDefault == true } ?? same.first)?.index
        }
        var wantedSubtitle: Int?
        if choice.subtitleOff {
            wantedSubtitle = PlaybackContext.subtitlesOff
        } else if let language = choice.subtitleLanguage {
            let same = subtitles.filter { Language.same($0.language, language) }
            let kind = same.filter { ($0.isForced == true) == choice.subtitleForced }
            wantedSubtitle = (kind.first { $0.title == choice.subtitleTitle } ?? kind.first ?? same.first)?.index
        }
        return (wantedAudio, wantedSubtitle)
    }
}

/// Languages as the server writes them (ISO 639-2, "eng", sometimes the
/// bibliographic "ger" for "deu") and as Apple's player does ("en").
enum Language {
    /// The two-letter code, where there is one; lowercased otherwise.
    static func short(_ code: String?) -> String? {
        guard let code = code?.lowercased(), !code.isEmpty, code != "und" else { return nil }
        if code.count == 2 { return code }
        let bibliographic = ["ger": "deu", "fre": "fra", "chi": "zho", "dut": "nld", "cze": "ces", "gre": "ell",
                             "per": "fas", "rum": "ron", "slo": "slk", "arm": "hye", "baq": "eus", "bur": "mya",
                             "geo": "kat", "ice": "isl", "mac": "mkd", "mao": "mri", "may": "msa", "tib": "bod",
                             "wel": "cym", "alb": "sqi"]
        let terminology = bibliographic[code] ?? code
        return Locale.LanguageCode(terminology).identifier(.alpha2) ?? terminology
    }

    static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a = short(a), let b = short(b) else { return false }
        return a == b
    }
}

/// "Only when needed" (Jellyfin's Smart subtitles) when the audio changes as
/// a film plays: the server applies it when it starts, by the default audio;
/// this is the same rule for the audio chosen since.
enum SubtitleRule {
    /// The subtitle to switch to for audio just chosen, by the player's id;
    /// nil to leave the subtitle as it is (the rule is off, or the audio's
    /// language isn't known, or there's nothing in the viewer's language).
    static func subtitle(afterChoosing audioId: String, tracks: TrackList, context: PlaybackContext?,
                         preferences: UserPreferences?) -> String? {
        guard let preferences, preferences.subtitleMode == .smart, !preferences.subtitleLanguage.isEmpty,
              let context,
              let audioIndex = context.serverIndex(forTrackId: audioId, in: tracks.audio, kind: "Audio"),
              let spoken = context.mediaStreams.first(where: { $0.type == "Audio" && $0.index == audioIndex })?.language,
              Language.short(spoken) != nil else { return nil }
        let mine = preferences.subtitleLanguage
        let inMine = context.mediaStreams.filter { $0.type == "Subtitle" && Language.same($0.language, mine) }
        func id(of stream: MediaStream?) -> String? {
            stream?.index.flatMap { context.trackId(forServerIndex: $0, in: tracks.subtitles, kind: "Subtitle") }
        }
        if Language.same(spoken, mine) {
            // Understood without them: only the forced ones (signs, a line in
            // another language), or none.
            return id(of: inMine.first { $0.isForced == true }) ?? TrackList.subtitlesOff
        }
        // Not understood: the full subtitles in the viewer's language.
        return id(of: inMine.first { $0.isForced != true })
    }
}
