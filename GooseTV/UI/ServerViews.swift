import SwiftUI

extension ServerFlavor {
    /// Each family's own colours, so a Jellyfin and an Emby server with the
    /// same name are told apart at a glance.
    var badgeColors: (Color, Color) {
        switch self {
        case .jellyfin: return (Color(red: 0.67, green: 0.36, blue: 0.76), Color(red: 0.0, green: 0.64, blue: 0.86))
        case .emby: return (Color(red: 0.32, green: 0.71, blue: 0.29), Color(red: 0.18, green: 0.49, blue: 0.16))
        }
    }
}

/// A server's square: its family's colours with a server drawn on it.
struct ServerBadge: View {
    let flavor: ServerFlavor?
    var size: CGFloat = 72

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(Theme.gradient(flavor?.badgeColors ?? Theme.primary, start: .topLeading, end: .bottomTrailing))
            .frame(width: size.scaled, height: size.scaled)
            .overlay {
                Image(systemName: "server.rack")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }
}

/// "JELLYFIN" or "EMBY", small, beside a server's name.
struct FlavorTag: View {
    let flavor: ServerFlavor

    var body: some View {
        Text(verbatim: flavor.label.uppercased())
            .font(.app(13, .heavy))
            .kerning(1.4)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 7).fill(.primary.opacity(0.12)))
    }
}

/// A server to pick: badge, name, family and address.
struct ServerCardLabel: View {
    let name: String
    let flavor: ServerFlavor?
    let address: String

    var body: some View {
        HStack(spacing: 22) {
            ServerBadge(flavor: flavor)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Text(name)
                        .font(.app(26, .heavy))
                        .lineLimit(1)
                    if let flavor { FlavorTag(flavor: flavor) }
                }
                Text(address)
                    .font(.app(18))
                    .opacity(0.65)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(26)
        .frame(width: CGFloat(460).scaled, alignment: .leading)
    }
}

/// Lifts to white with dark words when focused, like every control in the
/// app; glass with a hairline otherwise.
struct ServerCardStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused ? Color.black : Color.white)
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(focused ? Color.white : Color.white.opacity(0.06))
                    .overlay {
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(.white.opacity(focused ? 0 : 0.10), lineWidth: 1)
                    }
            }
            .scaleEffect(focused ? 1.05 : (configuration.isPressed ? 0.97 : 1))
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: 24, y: 12)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// The app's mark: the gradient tile with the play glyph, glowing.
struct BrandTile: View {
    var size: CGFloat = 104

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing))
            .frame(width: size.scaled, height: size.scaled)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: size * 0.42, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: size * 0.03)
            }
            .shadow(color: Theme.primary.0.opacity(0.6), radius: size * 0.6)
    }
}
