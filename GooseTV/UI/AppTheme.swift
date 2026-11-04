import SwiftUI

/// One complete colour scheme. Everything colourful in the app comes from here,
/// so a theme is these values and nothing else.
struct ThemeColors {
    let background: Color
    let surface: Color
    let accent: Color
    let accentSecondary: Color
    /// Four gradient pairs, used in order for shelves, chips and badges. Their
    /// roles are fixed so meaning survives a theme change: 0 is the app's own
    /// colour (Play buttons, the menu, focus), 1 is warm and carries destructive
    /// actions, 2 is cool, 3 is a second accent.
    let palette: [(Color, Color)]
    /// The two glows in the wallpaper: upper right, then lower left.
    let glowTop: Color
    let glowBottom: Color
}

/// The schemes on offer in Settings → Appearance.
enum AppTheme: String, CaseIterable, Identifiable {
    case violetSignal, ember, evergreen, blueHour, roseNoir, trueBlack

    static let storageKey = "goosetv.theme"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .violetSignal: return String(localized: "Violet Signal", comment: "Name of a colour scheme")
        case .ember: return String(localized: "Ember", comment: "Name of a colour scheme")
        case .evergreen: return String(localized: "Evergreen", comment: "Name of a colour scheme")
        case .blueHour: return String(localized: "Blue Hour", comment: "Name of a colour scheme")
        case .roseNoir: return String(localized: "Rose Noir", comment: "Name of a colour scheme")
        case .trueBlack: return String(localized: "True Black", comment: "Name of a colour scheme")
        }
    }

    var blurb: String {
        switch self {
        case .violetSignal: return String(localized: "Violet and blue over near-black. The original.")
        case .ember: return String(localized: "Warm amber over charcoal, like a lit room.")
        case .evergreen: return String(localized: "Soft sage green over deep green-grey, like a forest in the mist.", comment: "Description of the Evergreen colour scheme")
        case .blueHour: return String(localized: "Azure and cyan over deep navy, like dusk.")
        case .roseNoir: return String(localized: "Rose and violet over graphite.")
        case .trueBlack: return String(localized: "Pure black with steel and silver. Easiest on an OLED.")
        }
    }

    /// The scheme that looks least like this one: what the Requests section
    /// wears unless another is chosen, so that asking for what the server
    /// hasn't got doesn't look like browsing what it has.
    var counterpart: AppTheme {
        switch self {
        case .violetSignal: .ember
        case .ember: .blueHour
        case .evergreen: .roseNoir
        case .blueHour: .ember
        case .roseNoir: .evergreen
        case .trueBlack: .blueHour
        }
    }

    /// Built once per scheme. Views ask for these colours over a hundred
    /// times a render (every pill, row and badge), and building them afresh
    /// each time meant twenty-odd colours and an array on every ask.
    var colors: ThemeColors { Self.built[self]! }

    private static let built = Dictionary(uniqueKeysWithValues: allCases.map { ($0, $0.makeColors()) })

    private func makeColors() -> ThemeColors {
        switch self {
        case .violetSignal:
            return ThemeColors(
                background: Color(red: 0.05, green: 0.05, blue: 0.08),
                surface: Color(red: 0.11, green: 0.11, blue: 0.15),
                accent: Color(red: 0.66, green: 0.45, blue: 0.95),
                accentSecondary: Color(red: 0.00, green: 0.64, blue: 0.86),
                palette: [
                    (Color(red: 0.48, green: 0.27, blue: 0.90), Color(red: 0.00, green: 0.56, blue: 0.86)),
                    (Color(red: 0.85, green: 0.36, blue: 0.25), Color(red: 0.90, green: 0.60, blue: 0.10)),
                    (Color(red: 0.05, green: 0.55, blue: 0.45), Color(red: 0.21, green: 0.75, blue: 0.86)),
                    (Color(red: 0.80, green: 0.20, blue: 0.50), Color(red: 0.48, green: 0.27, blue: 0.90)),
                ],
                glowTop: Color(red: 0.23, green: 0.18, blue: 0.43),
                glowBottom: Color(red: 0.07, green: 0.23, blue: 0.36))

        case .ember:
            return ThemeColors(
                background: Color(red: 0.07, green: 0.05, blue: 0.05),
                surface: Color(red: 0.15, green: 0.11, blue: 0.10),
                accent: Color(red: 0.97, green: 0.66, blue: 0.28),
                accentSecondary: Color(red: 0.90, green: 0.38, blue: 0.20),
                palette: [
                    (Color(red: 0.90, green: 0.42, blue: 0.14), Color(red: 0.98, green: 0.72, blue: 0.22)),
                    (Color(red: 0.82, green: 0.22, blue: 0.18), Color(red: 0.95, green: 0.45, blue: 0.16)),
                    (Color(red: 0.16, green: 0.48, blue: 0.48), Color(red: 0.38, green: 0.76, blue: 0.70)),
                    (Color(red: 0.72, green: 0.28, blue: 0.34), Color(red: 0.94, green: 0.58, blue: 0.26)),
                ],
                glowTop: Color(red: 0.36, green: 0.18, blue: 0.07),
                glowBottom: Color(red: 0.24, green: 0.09, blue: 0.09))

        case .evergreen:
            // Sage (Sam's pick, 2026-10-17, over the brighter mint and teal it
            // had): soft grey-greens over a deep green-grey.
            return ThemeColors(
                background: Color(red: 0.051, green: 0.067, blue: 0.059),
                surface: Color(red: 0.102, green: 0.129, blue: 0.114),
                accent: Color(red: 0.639, green: 0.788, blue: 0.659),
                accentSecondary: Color(red: 0.498, green: 0.702, blue: 0.627),
                palette: [
                    (Color(red: 0.373, green: 0.541, blue: 0.416), Color(red: 0.553, green: 0.710, blue: 0.588)),
                    (Color(red: 0.85, green: 0.36, blue: 0.25), Color(red: 0.92, green: 0.62, blue: 0.12)),
                    (Color(red: 0.290, green: 0.451, blue: 0.478), Color(red: 0.522, green: 0.702, blue: 0.722)),
                    (Color(red: 0.620, green: 0.678, blue: 0.451), Color(red: 0.373, green: 0.541, blue: 0.416)),
                ],
                glowTop: Color(red: 0.149, green: 0.220, blue: 0.173),
                glowBottom: Color(red: 0.102, green: 0.180, blue: 0.169))

        case .blueHour:
            return ThemeColors(
                background: Color(red: 0.03, green: 0.04, blue: 0.09),
                surface: Color(red: 0.07, green: 0.10, blue: 0.18),
                accent: Color(red: 0.32, green: 0.66, blue: 1.00),
                accentSecondary: Color(red: 0.22, green: 0.82, blue: 0.90),
                palette: [
                    (Color(red: 0.12, green: 0.42, blue: 0.90), Color(red: 0.16, green: 0.74, blue: 0.92)),
                    (Color(red: 0.85, green: 0.30, blue: 0.18), Color(red: 0.94, green: 0.62, blue: 0.14)),
                    (Color(red: 0.10, green: 0.36, blue: 0.66), Color(red: 0.34, green: 0.78, blue: 0.95)),
                    (Color(red: 0.30, green: 0.24, blue: 0.86), Color(red: 0.26, green: 0.66, blue: 0.96)),
                ],
                glowTop: Color(red: 0.07, green: 0.15, blue: 0.34),
                glowBottom: Color(red: 0.04, green: 0.19, blue: 0.30))

        case .roseNoir:
            return ThemeColors(
                background: Color(red: 0.06, green: 0.05, blue: 0.07),
                surface: Color(red: 0.13, green: 0.11, blue: 0.15),
                accent: Color(red: 0.96, green: 0.48, blue: 0.68),
                accentSecondary: Color(red: 0.66, green: 0.42, blue: 0.88),
                palette: [
                    (Color(red: 0.84, green: 0.20, blue: 0.46), Color(red: 0.58, green: 0.26, blue: 0.78)),
                    (Color(red: 0.86, green: 0.30, blue: 0.26), Color(red: 0.93, green: 0.56, blue: 0.22)),
                    (Color(red: 0.28, green: 0.52, blue: 0.76), Color(red: 0.46, green: 0.76, blue: 0.88)),
                    (Color(red: 0.54, green: 0.24, blue: 0.72), Color(red: 0.86, green: 0.36, blue: 0.62)),
                ],
                glowTop: Color(red: 0.29, green: 0.12, blue: 0.26),
                glowBottom: Color(red: 0.12, green: 0.10, blue: 0.29))

        case .trueBlack:
            // Black means black: the wallpaper's glows are barely there, so an OLED
            // keeps its pixels off. Colour comes only from the controls themselves.
            return ThemeColors(
                background: .black,
                surface: Color(red: 0.09, green: 0.09, blue: 0.10),
                accent: Color(red: 0.82, green: 0.84, blue: 0.88),
                accentSecondary: Color(red: 0.52, green: 0.58, blue: 0.66),
                palette: [
                    (Color(red: 0.30, green: 0.33, blue: 0.40), Color(red: 0.58, green: 0.62, blue: 0.70)),
                    (Color(red: 0.80, green: 0.26, blue: 0.20), Color(red: 0.90, green: 0.52, blue: 0.16)),
                    (Color(red: 0.18, green: 0.44, blue: 0.54), Color(red: 0.38, green: 0.68, blue: 0.78)),
                    (Color(red: 0.42, green: 0.44, blue: 0.50), Color(red: 0.72, green: 0.74, blue: 0.80)),
                ],
                glowTop: Color(red: 0.07, green: 0.07, blue: 0.08),
                glowBottom: Color(red: 0.05, green: 0.05, blue: 0.06))
        }
    }
}

/// What the Requests section wears: the scheme least like the app's (the
/// default), the app's own, or one picked for it.
enum RequestsScheme: Equatable {
    case contrasting
    case same
    case fixed(AppTheme)

    static let storageKey = "goosetv.requestsTheme"

    init(stored: String?) {
        switch stored {
        case "same": self = .same
        case let name?: self = AppTheme(rawValue: name).map { .fixed($0) } ?? .contrasting
        case nil: self = .contrasting
        }
    }

    /// As it's kept: nothing for the default.
    var stored: String? {
        switch self {
        case .contrasting: nil
        case .same: "same"
        case .fixed(let theme): theme.rawValue
        }
    }

    /// The scheme it comes to, for someone whose own is `theme`.
    func theme(beside theme: AppTheme) -> AppTheme {
        switch self {
        case .contrasting: theme.counterpart
        case .same: theme
        case .fixed(let chosen): chosen
        }
    }
}
