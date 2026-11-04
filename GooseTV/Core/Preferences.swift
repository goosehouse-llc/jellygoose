import Foundation
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// Playback settings that belong to this Apple TV rather than the account:
/// what suits the living-room network here may not suit another device.
enum PlaybackPreferences {
    static let maxBitrateKey = "goosetv.maxBitrate"
    static let directPlayKey = "goosetv.directPlay"
    static let alwaysVLCKey = "goosetv.alwaysVLC"
    /// MKV files straight to VLC, unless they're Dolby Vision.
    static let vlcForMKVKey = "goosetv.vlcForMKV"
    /// iPhone and iPad: downloads wait for Wi-Fi rather than use mobile data.
    static let downloadsWiFiOnlyKey = "goosetv.downloadsWiFiOnly"
    /// How big a downloaded film or episode is (`DownloadQuality`).
    static let downloadQualityKey = "goosetv.downloadQuality"
    static var downloadQuality: DownloadQuality {
        DownloadQuality(rawValue: UserDefaults.standard.string(forKey: downloadQualityKey) ?? "") ?? .original
    }

    /// Intros and credits skipped as they start, rather than offered.
    static let autoSkipIntrosKey = "goosetv.autoSkipIntros"
    static let autoSkipCreditsKey = "goosetv.autoSkipCredits"

    static var autoSkipIntros: Bool { UserDefaults.standard.bool(forKey: autoSkipIntrosKey) }
    static var autoSkipCredits: Bool { UserDefaults.standard.bool(forKey: autoSkipCreditsKey) }

    /// A recording's commercial breaks skipped as they come, rather than
    /// offered. Off unless turned on, like the two above: the marks are a
    /// detector's, and now and then it takes the programme for a break.
    static let autoSkipCommercialsKey = "goosetv.autoSkipCommercials"
    static var autoSkipCommercials: Bool { UserDefaults.standard.bool(forKey: autoSkipCommercialsKey) }

    /// An episode's recap and its preview of the next, skipped as they come.
    static let autoSkipRecapsKey = "goosetv.autoSkipRecaps"
    static var autoSkipRecaps: Bool { UserDefaults.standard.bool(forKey: autoSkipRecapsKey) }

    /// The audio and subtitles chosen in a show, kept for its other episodes
    /// (see `TrackMemory`). On unless turned off.
    static let remembersTracksKey = "goosetv.remembersTracks"
    static var remembersTracks: Bool { UserDefaults.standard.object(forKey: remembersTracksKey) as? Bool ?? true }

    /// Apple TV: films and episodes that aren't HDR shown with the television
    /// in HDR, at their own frame rate, where Match Content would have taken
    /// it down to SDR. Most televisions run their HDR picture much brighter
    /// than their SDR one. Off unless turned on: switched to SDR, standard
    /// range is shown as it was made.
    static let sdrInHDRKey = "goosetv.sdrInHDR"
    static var sdrInHDR: Bool { UserDefaults.standard.bool(forKey: sdrInHDRKey) }

    /// On unless turned off: a film can be tens of gigabytes. Never on a Mac, which
    /// has no mobile data and no switch for it.
    static var downloadsWiFiOnly: Bool {
        #if os(macOS)
        false
        #else
        UserDefaults.standard.object(forKey: downloadsWiFiOnlyKey) as? Bool ?? true
        #endif
    }

    /// The ceiling sent as "Auto": high enough that only the file itself limits it.
    static let autoBitrate = 120_000_000

    static let bitrateChoices: [(label: String, bitsPerSecond: Int)] = [
        (String(localized: "Auto", comment: "Streaming quality: let the file set the bitrate"), autoBitrate),
        ("40 Mbps", 40_000_000),
        ("20 Mbps", 20_000_000),
        ("10 Mbps", 10_000_000),
        ("4 Mbps", 4_000_000),
    ]

    static var maxBitrate: Int {
        let stored = UserDefaults.standard.integer(forKey: maxBitrateKey)
        return stored > 0 ? stored : autoBitrate
    }

    /// Off forces a transcode, which can help with files that direct-play badly.
    static var allowDirectPlay: Bool {
        UserDefaults.standard.object(forKey: directPlayKey) as? Bool ?? true
    }

    /// Automatic sends only what AVPlayer can't decode to VLC; this sends everything.
    /// MKV files play in VLC straight from the file, so the server doesn't
    /// repackage them first: a quicker start, at the cost of the system
    /// player's handling (frame-rate matching and HomePod timing are its own).
    /// Dolby Vision stays with the system player, which alone shows it right.
    static var vlcForMKV: Bool {
        UserDefaults.standard.bool(forKey: vlcForMKVKey)
    }

    static var alwaysVLC: Bool {
        UserDefaults.standard.bool(forKey: alwaysVLCKey)
    }

    /// Video codecs AVPlayer decodes in hardware. Anything else goes to VLC.
    static let nativeVideoCodecs: Set<String> = ["h264", "hevc", "h265"]

    static func bitrateLabel(_ bitsPerSecond: Int) -> String {
        bitrateChoices.first { $0.bitsPerSecond == bitsPerSecond }?.label ?? "\(bitsPerSecond / 1_000_000) Mbps"
    }
}

/// The Jellyfin account preferences GooseTV reads and edits. They live on the
/// server, so they follow the user to every Jellyfin app.
struct UserPreferences: Equatable {
    /// Jellyfin's SubtitleMode values.
    enum SubtitleMode: String, CaseIterable {
        case smart = "Smart", always = "Always", onlyForced = "OnlyForced", `default` = "Default", none = "None"

        var label: String {
            switch self {
            case .smart: return String(localized: "Only when needed")
            case .always: return String(localized: "Always", comment: "Subtitle mode: always show subtitles")
            case .onlyForced: return String(localized: "Forced only", comment: "Subtitle mode: only forced subtitles")
            case .default: return String(localized: "When marked default")
            case .none: return String(localized: "Off", comment: "Subtitle mode: never show subtitles")
            }
        }

        var explanation: String {
            switch self {
            case .smart: return String(localized: "Shown when the audio isn't in your subtitle language.")
            case .always: return String(localized: "Shown whenever there's a track in your language.")
            case .onlyForced: return String(localized: "Only for foreign dialogue in otherwise-native audio.")
            case .default: return String(localized: "Shown when the file marks a subtitle track as default.")
            case .none: return String(localized: "Never turned on automatically.")
            }
        }
    }

    var subtitleMode: SubtitleMode
    /// ISO 639-2 code as Jellyfin stores it ("eng"); empty means any language.
    var subtitleLanguage: String
    var autoPlayNextEpisode: Bool

    init(configuration: [String: Any]) {
        subtitleMode = (configuration["SubtitleMode"] as? String).flatMap(SubtitleMode.init(rawValue:)) ?? .default
        subtitleLanguage = configuration["SubtitleLanguagePreference"] as? String ?? ""
        autoPlayNextEpisode = configuration["EnableNextEpisodeAutoPlay"] as? Bool ?? true
    }

    /// Writes these values over a full configuration, leaving every other field alone.
    func applied(to configuration: [String: Any]) -> [String: Any] {
        var updated = configuration
        updated["SubtitleMode"] = subtitleMode.rawValue
        updated["SubtitleLanguagePreference"] = subtitleLanguage
        updated["EnableNextEpisodeAutoPlay"] = autoPlayNextEpisode
        return updated
    }

    var subtitleLanguageName: String {
        SubtitleLanguage.all.first { $0.code == subtitleLanguage }?.name
            ?? (subtitleLanguage.isEmpty ? String(localized: "Any language", comment: "Subtitle language choice: no preference") : subtitleLanguage.uppercased())
    }
}

struct SubtitleLanguage {
    /// ISO 639-2/B, the form Jellyfin uses.
    let code: String
    /// ISO 639-1, the form AVFoundation's locales use.
    let shortCode: String
    let name: String

    static let all: [SubtitleLanguage] = [
        .init(code: "", shortCode: "", name: String(localized: "Any language", comment: "Subtitle language choice: no preference")),
        .init(code: "eng", shortCode: "en", name: "English"),
        .init(code: "spa", shortCode: "es", name: "Spanish"),
        .init(code: "fre", shortCode: "fr", name: "French"),
        .init(code: "ger", shortCode: "de", name: "German"),
        .init(code: "ita", shortCode: "it", name: "Italian"),
        .init(code: "por", shortCode: "pt", name: "Portuguese"),
        .init(code: "dut", shortCode: "nl", name: "Dutch"),
        .init(code: "swe", shortCode: "sv", name: "Swedish"),
        .init(code: "rus", shortCode: "ru", name: "Russian"),
        .init(code: "jpn", shortCode: "ja", name: "Japanese"),
        .init(code: "kor", shortCode: "ko", name: "Korean"),
        .init(code: "chi", shortCode: "zh", name: "Chinese"),
        .init(code: "ara", shortCode: "ar", name: "Arabic"),
        .init(code: "hin", shortCode: "hi", name: "Hindi"),
    ].map { (language: SubtitleLanguage) -> SubtitleLanguage in
        // Named in the viewer's own language; the English name is the fallback.
        guard !language.shortCode.isEmpty,
              let name = Locale.current.localizedString(forLanguageCode: language.shortCode) else { return language }
        return SubtitleLanguage(code: language.code, shortCode: language.shortCode, name: name)
    }

    static func shortCode(for code: String) -> String? {
        all.first { $0.code == code }?.shortCode
    }
}

/// How subtitles look (shared through iCloud): the ones the app draws itself
/// (a transcode's, the files beside a film, everything AetherEngine plays)
/// and the ones VLC draws, which is told the same choices. Subtitles inside a
/// file Apple's player plays directly are the system's, in the Apple TV's own
/// caption style.
enum SubtitleAppearance {
    static let sizeKey = "goosetv.subtitleSize"
    static let tintKey = "goosetv.subtitleColour"
    static let backingKey = "goosetv.subtitleBackground"
    static let placeKey = "goosetv.subtitlePosition"

    /// The colour of the words. Grey is for a dark room, where white lines on
    /// a dim picture are the brightest thing in it.
    enum Tint: String, CaseIterable {
        case white, grey, yellow, cyan

        var label: String {
            switch self {
            case .white: String(localized: "White", comment: "Subtitle colour")
            case .grey: String(localized: "Grey", comment: "Subtitle colour")
            case .yellow: String(localized: "Yellow", comment: "Subtitle colour")
            case .cyan: String(localized: "Cyan", comment: "Subtitle colour")
            }
        }

        /// Red, green and blue, each out of 255.
        var rgb: (Int, Int, Int) {
            switch self {
            case .white: (255, 255, 255)
            case .grey: (176, 176, 176)
            case .yellow: (255, 224, 64)
            case .cyan: (96, 232, 255)
            }
        }
    }

    /// What's behind the words: nothing but their own dark edge, or a plate
    /// that keeps them readable over anything.
    enum Backing: String, CaseIterable {
        case none, shaded, solid

        var label: String {
            switch self {
            case .none: String(localized: "None", comment: "Subtitle background: no box behind the words")
            case .shaded: String(localized: "Shaded", comment: "Subtitle background: a see-through dark box behind the words")
            case .solid: String(localized: "Solid", comment: "Subtitle background: a black box behind the words")
            }
        }

        /// How dark the plate is, nought to one.
        var opacity: Double {
            switch self {
            case .none: 0
            case .shaded: 0.55
            case .solid: 1
            }
        }
    }

    /// How far up from the bottom of the screen the lines sit: lower, into
    /// the black bar under a wide film; higher, clear of a soundbar.
    enum Place: String, CaseIterable {
        case lower, standard, higher

        var label: String {
            switch self {
            case .lower: String(localized: "Lower", comment: "Subtitle position: nearer the bottom of the screen")
            case .standard: String(localized: "Standard", comment: "Subtitle position: the usual place")
            case .higher: String(localized: "Higher", comment: "Subtitle position: further up the screen")
            }
        }

        /// Points up from the bottom of a screen `shorter` points on its
        /// shorter side. Standard is where the lines have always been; higher
        /// is twice that, but never a third of the way up a phone.
        func rise(onScreen shorter: CGFloat) -> CGFloat {
            switch self {
            case .lower: 36
            case .standard: 80
            case .higher: min(160, max(shorter * 0.3, 80))
            }
        }

        /// With the player's controls up: clear of them, as ever.
        func rise(onScreen shorter: CGFloat, controlsUp: Bool) -> CGFloat {
            let resting = rise(onScreen: shorter)
            return controlsUp ? max(resting + 170, 250) : resting
        }
    }

    /// The same choices as VLC takes them, for the subtitles it draws itself.
    /// Its sizes are a fraction of the picture's height (a sixteenth, left
    /// alone, which is larger than the largest here). Its lines rest about
    /// fifty points up; the margin, which it counts in the screen's own
    /// pixels, lifts them the rest of the way, and can't lower them.
    @MainActor static var vlcOptions: [String] {
        let (red, green, blue) = tint.rgb
        // The window's, not the whole screen's: an iPhone Duo's open and
        // folded screens differ. (The widgets and the Top Shelf compile this
        // file too, and have no window of the app's.)
        #if (os(iOS) || os(macOS)) && !EXTENSION
        let window = AppWindow.size, scale = AppWindow.scale
        #else
        let window = UIScreen.main.bounds.size, scale = UIScreen.main.scale
        #endif
        let shorter = min(window.width, window.height)
        let lift = max(place.rise(onScreen: shorter) - 50, 0) * scale
        return [
            "--freetype-rel-fontsize=\(Int((1080 / size.points).rounded()))",
            "--freetype-color=\(red << 16 | green << 8 | blue)",
            "--freetype-background-color=0",
            "--freetype-background-opacity=\(Int(backing.opacity * 255))",
            "--sub-margin=\(Int(lift))",
        ]
    }

    static var tint: Tint { Tint(rawValue: UserDefaults.standard.string(forKey: tintKey) ?? "") ?? .white }
    static var backing: Backing { Backing(rawValue: UserDefaults.standard.string(forKey: backingKey) ?? "") ?? .none }
    static var place: Place { Place(rawValue: UserDefaults.standard.string(forKey: placeKey) ?? "") ?? .standard }

    enum Size: String, CaseIterable {
        case small, medium, large, extraLarge

        var label: String {
            switch self {
            case .small: String(localized: "Small", comment: "Subtitle text size")
            case .medium: String(localized: "Medium", comment: "Subtitle text size")
            case .large: String(localized: "Large", comment: "Subtitle text size")
            case .extraLarge: String(localized: "Extra Large", comment: "Subtitle text size")
            }
        }

        /// Points on a 1080p screen; medium is the size tvOS uses for its own.
        var points: CGFloat {
            switch self {
            case .small: 38
            case .medium: 48
            case .large: 60
            case .extraLarge: 74
            }
        }
    }

    static var size: Size {
        Size(rawValue: UserDefaults.standard.string(forKey: sizeKey) ?? "") ?? .medium
    }
}

/// Which films the Apple TV plays from the original file through AetherEngine:
/// those Apple's player could play but not open as they are (an MKV, or an MP4
/// whose sound it can't take), which the server would otherwise convert first,
/// and those whose subtitle is a picture (Blu-ray, DVD), which Apple's player
/// can't show at all. Played this way they start at once, and Dolby Vision,
/// Atmos and the TV's mode switch stay Apple's. What Apple's player can't
/// decode at all still goes to VLC, and a film over the quality cap is still
/// converted by the server.
enum OnDevicePlayback {
    /// Containers and sounds Apple's player takes straight from the server.
    private static let directContainers: Set<String> = ["mp4", "m4v", "mov"]
    private static let directAudio: Set<String> = ["aac", "ac3", "eac3", "alac", "flac"]

    static func wanted(_ item: BaseItem, source: MediaSource?, audioIndex: Int?, subtitleIndex: Int?,
                       maxBitrate: Int) -> Bool {
        #if os(tvOS)
        guard PlaybackPreferences.allowDirectPlay, !PlaybackPreferences.alwaysVLC,
              !refused(item.id), let source else { return false }
        if let bitrate = source.bitrate, bitrate > maxBitrate { return false }
        let streams = source.mediaStreams ?? []
        guard let video = streams.first(where: { $0.type == "Video" })?.codec?.lowercased(),
              PlaybackPreferences.nativeVideoCodecs.contains(video) else { return false }
        let subtitleIndex = subtitleIndex ?? source.defaultSubtitleStreamIndex
        if streams.contains(where: { $0.index == subtitleIndex && $0.isEmbeddedPictureSubtitle }) { return true }
        let containers = Set((source.container ?? "").lowercased().split(separator: ",").map(String.init))
        let audioIndex = audioIndex ?? source.defaultAudioStreamIndex
        let audio = streams.first { $0.type == "Audio" && $0.index == audioIndex }
            ?? streams.first { $0.type == "Audio" }
        let opensAsItIs = !containers.isDisjoint(with: directContainers)
            && (audio?.codec).map { directAudio.contains($0.lowercased()) } ?? true
        return !opensAsItIs
        #else
        return false
        #endif
    }

    // A film AetherEngine couldn't play, which plays the usual way for the
    // rest of the time the app is open.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var refusedIDs: Set<String> = []

    static func refused(_ itemId: String) -> Bool {
        lock.withLock { refusedIDs.contains(itemId) }
    }

    static func refuse(_ itemId: String) {
        lock.withLock { _ = refusedIDs.insert(itemId) }
    }
}

/// How big a downloaded film or episode is: the file on the server as it is,
/// or a smaller copy the server makes as it comes down (H.264 and AAC in an
/// MP4, at most this tall and this many bits a second). A file already within
/// the choice comes down as it is, with all its tracks.
enum DownloadQuality: String, CaseIterable, Identifiable {
    case original, high, medium, low

    var id: String { rawValue }

    /// The tallest picture, nil for the file as it is.
    var maxHeight: Int? {
        switch self {
        case .original: nil
        case .high: 1080
        case .medium: 720
        case .low: 480
        }
    }

    var maxWidth: Int? { maxHeight.map { $0 * 16 / 9 } }

    var videoBitrate: Int {
        switch self {
        case .original: 0
        case .high: 6_000_000
        case .medium: 3_000_000
        case .low: 1_200_000
        }
    }

    var audioBitrate: Int {
        switch self {
        case .original: 0
        case .high: 384_000
        case .medium: 160_000
        case .low: 128_000
        }
    }

    /// Surround kept at High; stereo below it.
    var audioChannels: Int { self == .high ? 6 : 2 }

    var label: String {
        switch self {
        case .original: String(localized: "Original", comment: "Download quality: the file as it is on the server")
        case .high: String(localized: "High (1080p)", comment: "Download quality")
        case .medium: String(localized: "Medium (720p)", comment: "Download quality")
        case .low: String(localized: "Low (480p)", comment: "Download quality")
        }
    }

    /// About how much an hour of it takes: nil for the original, which is as big as it is.
    var bytesPerHour: Int64? {
        self == .original ? nil : Int64(videoBitrate + audioBitrate) * 3600 / 8
    }

    /// Whether a file has to be made smaller to be within this: taller, or
    /// heavier by more than a quarter. A file whose rate the server doesn't
    /// know is made smaller.
    func converts(_ source: MediaSource) -> Bool {
        guard let maxHeight else { return false }
        let picture = source.mediaStreams?.first { $0.type == "Video" }
        if (picture?.height ?? Int.max) > maxHeight + 16 { return true }
        return (source.bitrate ?? Int.max) > (videoBitrate + audioBitrate) * 5 / 4
    }
}

