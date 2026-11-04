import SwiftUI

/// The app in one window. Supporting several scenes is what gives the car its
/// screen, but it also lets an iPhone Duo, open, show the app twice side by
/// side, both sharing one player and one signed-in state. iOS won't let an
/// iPhone app close a window itself, so the first window is the app and any
/// other only says where the app is, with a way there. (On an iPad, where
/// there's no car, the app keeps to one window by its Info.plist.)
struct OneWindowGate<Content: View>: View {
    @ViewBuilder let content: () -> Content

    #if os(iOS)
    /// Undecided until the window is known, then whether it's the app's.
    @State private var isMain: Bool?
    @State private var scene: UIWindowScene?

    var body: some View {
        ZStack {
            switch isMain {
            case true?: content()
            case false?: AnotherWindowNotice { become in
                if let scene { isMain = OneWindow.goToMain(from: scene, takeOver: become) }
            }
            case nil: Color.clear
            }
        }
        .background {
            WindowSentinel { found in
                scene = found
                isMain = OneWindow.isMain(found)
            }
            .frame(width: 0, height: 0)
        }
    }
    #else
    var body: some View { content() }
    #endif
}

#if os(iOS)
@MainActor
enum OneWindow {
    /// The app's window: the first to appear.
    private static weak var main: UIWindowScene?
    /// For what opens a window of its own over the app's (the player).
    static var mainScene: UIWindowScene? { main }

    static func isMain(_ scene: UIWindowScene) -> Bool {
        guard scene.session.role == .windowApplication else { return true }
        if let main, main !== scene, UIApplication.shared.connectedScenes.contains(main) {
            note("another window: \(scene.session.persistentIdentifier); the app's is \(main.session.persistentIdentifier)")
            return false
        }
        main = scene
        #if DEBUG
        // GOOSETV_SECOND_WINDOW=1 asks for another window a moment after the
        // first, to see what it shows.
        if ProcessInfo.processInfo.environment["GOOSETV_SECOND_WINDOW"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
                UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(role: .windowApplication)) {
                    note("second window refused: \($0)")
                }
            }
        }
        #endif
        return true
    }

    /// From another window: to the app's, or, where that's gone, this one
    /// becomes the app's. Whether this one is the app's now.
    static func goToMain(from scene: UIWindowScene, takeOver: Bool) -> Bool {
        if let main, main !== scene, UIApplication.shared.connectedScenes.contains(main) {
            UIApplication.shared.activateSceneSession(for: UISceneSessionActivationRequest(session: main.session))
            return false
        }
        main = scene
        return true
    }

    private static func note(_ what: String) {
        #if DEBUG
        NSLog("GOOSETV one window: %@", what)
        #endif
    }
}

/// Finds the window scene it's shown in.
private struct WindowSentinel: UIViewRepresentable {
    let found: (UIWindowScene) -> Void

    func makeUIView(context: Context) -> Sentinel { Sentinel(found: found) }
    func updateUIView(_ uiView: Sentinel, context: Context) {}

    final class Sentinel: UIView {
        let found: (UIWindowScene) -> Void
        init(found: @escaping (UIWindowScene) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let scene = window?.windowScene { found(scene) }
        }
    }
}

/// What a second window of the app shows instead of a second app.
private struct AnotherWindowNotice: View {
    /// Called with whether to become the app's window if the other's gone.
    let goToMain: (Bool) -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            Text("JellyGoose is open in another window.",
                 comment: "Shown in a second window of the app, which the app doesn't fill: it's open in the first")
                .font(.app(30, .semibold))
                .multilineTextAlignment(.center)
            Button {
                goToMain(true)
            } label: {
                Text("Go to JellyGoose", comment: "Button in a second window of the app: brings the first one forward")
                    .font(.app(26, .semibold))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(Capsule().fill(Theme.gradient(Theme.primary)))
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppWallpaper(theme: Theme.selected).ignoresSafeArea())
    }
}
#endif
