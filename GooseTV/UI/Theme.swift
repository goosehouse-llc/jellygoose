import SwiftUI

enum Theme {
    /// The scheme in force. AppState owns the choice and sets this; views redraw
    /// because they observe AppState.
    static var selected: AppTheme = AppTheme(rawValue: UserDefaults.standard
        .string(forKey: AppTheme.storageKey) ?? "") ?? .violetSignal {
        didSet { colors = selected.colors }
    }

    /// The selected scheme's colours, kept rather than looked up each time.
    private(set) static var colors: ThemeColors = selected.colors

    static var background: Color { colors.background }
    static var surface: Color { colors.surface }
    static var accent: Color { colors.accent }
    static var accentSecondary: Color { colors.accentSecondary }
    static let textSecondary = Color.white.opacity(0.6)

    #if os(tvOS)
    static let posterWidth: CGFloat = 220
    static let landscapeWidth: CGFloat = 400
    #else
    // Held at arm's length, not watched from the sofa: more to a row, and more
    // again on a phone.
    static let posterWidth: CGFloat = isPhone ? 110 : 150
    static let landscapeWidth: CGFloat = isPhone ? 240 : 280
    #endif

    #if os(iOS)
    static let isPhone = UIDevice.current.userInterfaceIdiom == .phone
    #else
    static let isPhone = false
    #endif
    /// The space either side of a page's content.
    static let pageMargin: CGFloat = isPhone ? 16 : 40

    /// The app's gradient identity. Everything colorful draws from these pairs.
    static var palette: [(Color, Color)] { colors.palette }

    static var primary: (Color, Color) { palette[0] }

    /// How much larger than their design sizes text and controls are drawn. Fonts
    /// (Font.app) and control chrome (`.scaled`) share it, so they grow together;
    /// artwork and page margins don't.
    #if os(tvOS)
    static let uiScale: CGFloat = 1.15
    #else
    /// Read at arm's length, the TV's sizes shrink to a tablet's, and further
    /// to a phone's.
    static let uiScale: CGFloat = isPhone ? 0.68 : 0.85
    #endif

    /// The pixels a picture this many points wide covers on this screen, to
    /// ask the server for: twice the points on a 4K Apple TV. Capped at 4K.
    static func pixels(_ points: CGFloat, scale: CGFloat) -> Int {
        min(Int(points * max(scale, 1)), 3840)
    }

    static func gradient(_ pair: (Color, Color),
                         start: UnitPoint = .leading,
                         end: UnitPoint = .trailing) -> LinearGradient {
        LinearGradient(colors: [pair.0, pair.1], startPoint: start, endPoint: end)
    }
}

/// The scheme in force, carried through the view tree.
///
/// `Theme.selected` is a global, and a global is invisible to SwiftUI: a view
/// whose own inputs haven't changed is never asked to draw again, so it keeps
/// the colours of the scheme it was built under. Reading the scheme from the
/// environment makes every view that uses it a view SwiftUI knows to invalidate.
private struct AppThemeKey: EnvironmentKey {
    static var defaultValue: AppTheme { Theme.selected }
}

extension EnvironmentValues {
    var appTheme: AppTheme {
        get { self[AppThemeKey.self] }
        set { self[AppThemeKey.self] = newValue }
    }
}

extension View {
    /// Hands the current scheme down the tree, so a change repaints everything
    /// that draws from it rather than only what happened to be rebuilt anyway.
    func themed(_ theme: AppTheme) -> some View {
        environment(\.appTheme, theme)
    }

    /// Full-bleed app background.
    func appBackground() -> some View {
        background(AppWallpaper(theme: Theme.selected).ignoresSafeArea())
    }
}

/// The wallpaper: one glow upper right, another lower left, settling into the
/// base colour toward the bottom and left edges. Both come from the theme.
struct AppWallpaper: View {
    /// Held here rather than read from `Theme` inside the body. A view that
    /// stores nothing is one SwiftUI can skip redrawing, and this one did: every
    /// other colour changed with the scheme while the wallpaper stayed on the
    /// old one until the app was launched again.
    var theme: AppTheme = Theme.selected

    private var colors: ThemeColors { theme.colors }

    var body: some View {
        ZStack {
            colors.background
            EllipticalGradient(colors: [colors.glowTop, .clear],
                               center: UnitPoint(x: 0.72, y: 0.3),
                               startRadiusFraction: 0, endRadiusFraction: 0.6)
            EllipticalGradient(colors: [colors.glowBottom, .clear],
                               center: UnitPoint(x: 0.3, y: 0.8),
                               startRadiusFraction: 0, endRadiusFraction: 0.7)
            LinearGradient(colors: [colors.background, .clear],
                           startPoint: .bottom, endPoint: UnitPoint(x: 0.5, y: 0.45))
            LinearGradient(colors: [.black.opacity(0.45), .clear],
                           startPoint: .leading, endPoint: UnitPoint(x: 0.6, y: 0.5))
        }
        // One scheme melts into the next, as on the way into the Requests
        // section and out of it.
        .animation(.easeInOut(duration: 0.35), value: theme)
    }
}

/// The wallpaper of the Requests section: the scheme it wears, and a good
/// deal more of it than a wallpaper usually carries. The app's own is a dark
/// room with a glow in two corners; this one is the colour itself, washed
/// down from the top, so there's no taking the section for the library.
struct RequestsWallpaper: View {
    var theme: AppTheme

    var body: some View {
        let colors = theme.colors
        let pair = colors.palette[0]
        ZStack {
            colors.background
            // The scheme's own colour, down from the top…
            LinearGradient(stops: [.init(color: pair.0.opacity(0.74), location: 0),
                                   .init(color: pair.0.opacity(0.44), location: 0.5),
                                   .init(color: pair.0.opacity(0.20), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            // …its lighter half glowing in the upper right, and again, lower
            // and fainter, on the left…
            EllipticalGradient(colors: [pair.1.opacity(0.36), .clear],
                               center: UnitPoint(x: 0.8, y: 0.12),
                               startRadiusFraction: 0, endRadiusFraction: 0.75)
            EllipticalGradient(colors: [pair.1.opacity(0.18), .clear],
                               center: UnitPoint(x: 0.15, y: 0.9),
                               startRadiusFraction: 0, endRadiusFraction: 0.6)
            // …and all of it deep enough for white words to be read on.
            Color.black.opacity(0.18)
        }
    }
}

extension Font {
    /// The app typeface (Figtree, bundled) at a fixed point size, like `.system(size:weight:)`.
    static func app(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        let face: String
        switch weight {
        case .black: face = "Figtree-Black"
        case .heavy: face = "Figtree-ExtraBold"
        case .bold: face = "Figtree-Bold"
        case .semibold: face = "Figtree-SemiBold"
        case .medium: face = "Figtree-Medium"
        default: face = "Figtree-Regular"
        }
        return .custom(face, fixedSize: size * Theme.uiScale)
    }
}

extension CGFloat {
    /// A control dimension (padding, icon box, fixed width) at the UI scale, so the
    /// control keeps its proportions around text that has grown.
    var scaled: CGFloat { self * Theme.uiScale }
}
