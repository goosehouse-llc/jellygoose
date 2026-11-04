import SwiftUI

/// What the app is built from, and on what terms.
///
/// VLCKit, AetherEngine and FFmpeg are LGPL: shipping them obliges the app to
/// carry each licence, say that it uses the library, and tell people where the
/// library's source is. The typeface is under the Open Font License, which asks
/// for the same acknowledgement. Seerr's mark, at the head of Requests, is a
/// file out of Seerr, which is MIT: the notice goes where the file goes. The
/// licences are bundled with the app; this is where a viewer can read them.
struct LicensesView: View {
    @Environment(\.isNarrow) private var narrow
    @State private var showing: Component = .aetherEngine

    enum Component: String, CaseIterable, Identifiable {
        case aetherEngine, ffmpeg, vlckit, figtree, seerr

        var id: String { rawValue }

        var title: String {
            switch self {
            case .aetherEngine: return "AetherEngine"
            case .ffmpeg: return "FFmpeg"
            case .vlckit: return "VLCKit"
            case .figtree: return "Figtree"
            case .seerr: return "Seerr"
            }
        }

        var terms: String {
            switch self {
            case .aetherEngine: return "GNU Lesser General Public License, version 3, with an App Store exception"
            case .ffmpeg: return "GNU Lesser General Public License, version 2.1 or later, and others"
            case .vlckit: return "GNU Lesser General Public License, version 2.1 or later"
            case .figtree: return "SIL Open Font License, version 1.1"
            case .seerr: return "MIT License"
            }
        }

        var credit: String {
            switch self {
            case .aetherEngine:
                return String(localized: "Copyright © Vincent Herbst. JellyGoose plays MKV films straight from the file with AetherEngine 7.24.0, used unmodified as a Swift package. Its source is at github.com/superuser404notfound/AetherEngine, at the tag matching that version.",
                              comment: "Licence credit for the AetherEngine video library. Keep the version, names and web addresses as they are")
            case .ffmpeg:
                return String(localized: "Copyright © the FFmpeg developers. AetherEngine reads films with FFmpeg, built with dav1d, zimg and libzvbi as dynamically linked frameworks from github.com/superuser404notfound/FFmpegBuild (version 3.6.0), and reads Dolby Vision with libdovi from github.com/superuser404notfound/LibDovi. Their licences follow, each in full.",
                              comment: "Licence credit for the FFmpeg libraries. Keep the versions, names and web addresses as they are")
            case .vlckit:
                #if os(tvOS)
                return String(localized: "Copyright © VideoLAN and the VLC authors. JellyGoose plays formats the Apple TV can't decode with VLCKit 3.6.0, used unmodified as a dynamically linked framework. Its source is at code.videolan.org/videolan/VLCKit, at the tag matching that version; the build shipped here comes from the VLCKit-all XCFramework published at github.com/tylerjonesio/vlckit-spm.",
                              comment: "Licence credit for the VLCKit video library. Keep the version, names and web addresses as they are")
                #else
                return String(localized: "Copyright © VideoLAN and the VLC authors. JellyGoose plays formats this device can't decode with VLCKit 3.6.0, used unmodified as a dynamically linked framework. Its source is at code.videolan.org/videolan/VLCKit, at the tag matching that version; the build shipped here comes from the VLCKit-all XCFramework published at github.com/tylerjonesio/vlckit-spm.",
                              comment: "Licence credit for the VLCKit video library. Keep the version, names and web addresses as they are")
                #endif
            case .figtree:
                return String(localized: "Copyright © The Figtree Project Authors. Figtree is the typeface used throughout the app, from github.com/erikdkennedy/figtree.",
                              comment: "Licence credit for the app's typeface. Keep the names and web address as they are")
            case .seerr:
                return String(localized: "Copyright © 2020 sct. The mark at the head of Requests is Seerr's own, as Seerr publishes it, from github.com/seerr-team/seerr. Seerr is a project of its own; JellyGoose isn't affiliated with it.",
                              comment: "Licence credit for the Seerr logo shown on the Requests page. Keep the names and web address as they are; Requests is the app's section of that name")
            }
        }

        /// The licence file bundled with the app.
        var fileName: String {
            switch self {
            case .aetherEngine: return "AetherEngine"
            case .ffmpeg: return "FFmpeg"
            case .vlckit: return "LGPL-2.1"
            case .figtree: return "OFL"
            case .seerr: return "Seerr"
            }
        }
    }

    var body: some View {
        SettingsPage(title: String(localized: "Licences"), accent: Theme.palette[3]) {
            Text("JellyGoose is built on other people's work. These are their terms.")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)

            // The list beside the text; on a phone, above it, where beside
            // it left the text a few points wide.
            let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: 24))
                                : AnyLayout(HStackLayout(alignment: .top, spacing: 24))
            layout {
                VStack(spacing: 18) {
                    ForEach(Component.allCases) { component in
                        Button { showing = component } label: {
                            ComponentRow(component: component, selected: showing == component)
                        }
                        .buttonStyle(SettingsRowStyle())
                    }
                }
                .frame(width: narrow ? nil : CGFloat(420).scaled)
                .tvFocusSection()

                LicenceText(component: showing)
                    .frame(maxWidth: .infinity)
                    .tvFocusSection()
            }
        }
    }
}

private struct ComponentRow: View {
    let component: LicensesView.Component
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(component.title).font(.app(20, .semibold))
            Text(component.terms)
                .font(.app(14))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, CGFloat(22).scaled)
        .padding(.vertical, CGFloat(16).scaled)
        .overlay(alignment: .trailing) {
            if selected {
                Image(systemName: "chevron.right")
                    .font(.app(13, .bold))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.trailing, CGFloat(18).scaled)
            }
        }
    }
}

/// The credit, then the licence itself. The text scrolls: the remote moves it,
/// so the whole thing has to be focusable to take the scroll.
private struct LicenceText: View {
    let component: LicensesView.Component

    var body: some View {
        let text = Self.text(of: component)
        VStack(alignment: .leading, spacing: 14) {
            Text(component.credit)
                .font(.app(16))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                Text(text.isEmpty ? String(localized: "The licence file is missing from this build.") : text)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(CGFloat(20).scaled)
                    .focusable()
            }
            .background(Theme.surface.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    /// The bundled licences, read once each. Read as the page drew rather
    /// than after, so there's no moment of "missing" before each one shows.
    @MainActor private static var texts: [LicensesView.Component: String] = [:]

    @MainActor private static func text(of component: LicensesView.Component) -> String {
        if let read = texts[component] { return read }
        let read = Bundle.main.url(forResource: component.fileName, withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        texts[component] = read
        return read
    }
}
