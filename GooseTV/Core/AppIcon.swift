import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The icons the app ships with. tvOS swaps between them by the name of an image
/// stack in the asset catalog; the default one is part of the brand assets and has
/// no name of its own, which is what `alternateName == nil` means.
enum AppIcon: String, CaseIterable, Identifiable {
    // The order here is the order they appear in Settings.
    case jellygoose, neon, playBeak, movieNight, playTile, marquee

    var id: String { rawValue }

    /// The image stack's name, or nil for the icon built into the brand assets.
    var alternateName: String? {
        switch self {
        case .jellygoose: return nil
        case .movieNight: return "MovieNight"
        case .playBeak: return "PlayBeak"
        case .neon: return "Neon"
        case .playTile: return "PlayTile"
        // The asset's name, which must never be translated.
        case .marquee: return "Marquee"
        }
    }

    var label: String {
        switch self {
        case .movieNight: return String(localized: "Movie Night")
        case .jellygoose: return "Jellygoose"
        case .playBeak: return String(localized: "Play Beak")
        case .neon: return String(localized: "Neon Sign")
        case .marquee: return String(localized: "Marquee", comment: "Name of an app icon styled like a cinema marquee sign")
        case .playTile: return String(localized: "Play Tile", comment: "Name of an app icon: a rounded tile with a play button")
        }
    }

    var blurb: String {
        switch self {
        case .movieNight: return String(localized: "The goose on the couch, lit by the screen.")
        case .jellygoose: return String(localized: "The jellyfish with a goose's eye and beak.")
        case .playBeak: return String(localized: "A goose whose beak is the play button.")
        case .neon: return String(localized: "The same creature, drawn in neon on black.")
        case .marquee: return String(localized: "The play button, big and bright on the gradient.")
        case .playTile: return String(localized: "The play button from the website, glowing in the dark.")
        }
    }

    /// The flattened artwork, for showing the icon inside the app.
    var preview: String {
        switch self {
        case .movieNight: return "movie-night"
        case .jellygoose: return "jellygoose"
        case .playBeak: return "play-beak"
        case .neon: return "neon"
        case .marquee: return "marquee"
        case .playTile: return "play-tile"
        }
    }

    /// What tvOS is showing now. The system is the source of truth, so an icon
    /// set on another device or reset by a reinstall doesn't show up wrong here.
    @MainActor
    static var current: AppIcon {
        let name = UIApplication.shared.alternateIconName
        return allCases.first { $0.alternateName == name } ?? .movieNight
    }

    /// Puts the icon back to the default if tvOS is showing an alternate this
    /// version no longer ships. Without this, an icon chosen in an older build
    /// stays on the Home screen under a name nothing answers to any more.
    @MainActor
    static func resetIfUnknown() async {
        // Known means listed in this build, not merely designed: an update that
        // stops shipping an icon has to put the Apple TV back on the default.
        // tvOS lists them as an array of names; iOS as a dictionary keyed by name;
        // a Mac has a Dock image for each (see UIApplication's Mac stand-in).
        #if os(macOS)
        let shipped = Set(allCases.compactMap(\.alternateName).filter { NSImage(named: "dock-\($0)") != nil })
        #else
        let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any]
        let listed = icons?["CFBundleAlternateIcons"]
        let shipped = Set(listed as? [String] ?? (listed as? [String: Any]).map { Array($0.keys) } ?? [])
        #endif
        guard let name = UIApplication.shared.alternateIconName, !shipped.contains(name) else { return }
        // tvOS cancels an icon change made while the app is still starting, so
        // this waits, and tries again if it is refused anyway.
        for attempt in 1...3 {
            try? await Task.sleep(for: .seconds(attempt == 1 ? 4 : 3))
            if (try? await UIApplication.shared.setAlternateIconName(nil)) != nil { return }
        }
    }

    /// Asks tvOS to switch. The reason is nil on success, and otherwise something
    /// short enough to show on screen: the Apple TV simulator, for one, refuses
    /// outright, so the app has to say so rather than look broken.
    @MainActor
    static func use(_ icon: AppIcon) async -> String? {
        guard UIApplication.shared.supportsAlternateIcons else {
            #if os(tvOS)
            return String(localized: "This Apple TV doesn't allow a different icon.")
            #else
            return String(localized: "This device doesn't allow a different icon.")
            #endif
        }
        guard icon.alternateName != UIApplication.shared.alternateIconName else { return nil }
        do {
            try await UIApplication.shared.setAlternateIconName(icon.alternateName)
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
