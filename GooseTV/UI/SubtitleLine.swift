import SwiftUI

/// A subtitle as the app draws it in SwiftUI: AetherEngine's lines over the
/// picture, and the sample in Settings. In the colour, on the background and
/// at the size chosen there; `scale` is for a screen smaller than a
/// television's 1080 points, which the sizes are given for.
struct SubtitleLine: View {
    let text: String
    var scale: CGFloat = 1
    var size = SubtitleAppearance.size
    var tint = SubtitleAppearance.tint
    var backing = SubtitleAppearance.backing

    /// How far the plate reaches past the words, at full scale: what the
    /// lines' own place is measured clear of.
    static let inset = CGSize(width: 18, height: 8)

    var body: some View {
        Text(text)
            .font(.system(size: size.points * scale, weight: .semibold))
            .foregroundStyle(tint.color)
            .multilineTextAlignment(.center)
            .lineSpacing(4 * scale)
            .shadow(color: .black, radius: 1.5 * scale)
            .shadow(color: .black.opacity(0.9), radius: 4 * scale)
            .padding(.horizontal, Self.inset.width * scale)
            .padding(.vertical, Self.inset.height * scale)
            .background(.black.opacity(backing.opacity),
                        in: RoundedRectangle(cornerRadius: 8 * scale, style: .continuous))
    }
}

extension SubtitleAppearance.Tint {
    var color: Color {
        let (red, green, blue) = rgb
        return Color(red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }
}

/// The foot of a screen with a line on it, at the size, colour, background
/// and height the player will draw it: what Settings shows over the choices,
/// so each is seen as it's made. The strip's bottom edge is the screen's.
struct SubtitlePreview: View {
    let size: SubtitleAppearance.Size
    let tint: SubtitleAppearance.Tint
    let backing: SubtitleAppearance.Backing
    let place: SubtitleAppearance.Place

    /// The screen's shorter side, which the player sizes its lines by (the
    /// window's: on an iPhone Duo, whichever screen is in use).
    private var shorter: CGFloat {
        #if os(tvOS)
        1080
        #else
        let bounds = AppWindow.size
        return min(bounds.width, bounds.height)
        #endif
    }

    var body: some View {
        let scale = shorter / 1080
        // Room for the highest place and the largest size at once.
        let height = SubtitleAppearance.Place.higher.rise(onScreen: shorter)
            + SubtitleAppearance.Size.extraLarge.points * scale * 1.25 + 16
        ZStack(alignment: .bottom) {
            // A picture of sorts: dark at one side and bright at the other,
            // since a line has to be read over both.
            LinearGradient(stops: [.init(color: Color(red: 0.05, green: 0.07, blue: 0.12), location: 0),
                                   .init(color: Color(red: 0.20, green: 0.24, blue: 0.36), location: 0.45),
                                   .init(color: Color(red: 0.93, green: 0.80, blue: 0.58), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            SubtitleLine(text: String(localized: "This is how subtitles will look.", comment: "Sample line in the subtitle settings preview"),
                         scale: scale, size: size, tint: tint, backing: backing)
                .padding(.bottom, place.rise(onScreen: shorter) - SubtitleLine.inset.height * scale)
                .animation(.easeOut(duration: 0.2), value: place)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}
