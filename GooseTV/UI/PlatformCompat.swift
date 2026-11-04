import SwiftUI

extension EnvironmentValues {
    /// A phone's width: an iPhone, or an iPad app sharing the screen narrowly.
    /// Screens stack what sits side by side on a television or a tablet.
    var isNarrow: Bool {
        #if os(iOS)
        horizontalSizeClass == .compact
        #else
        false
        #endif
    }

    /// The side the system puts bars along where it doesn't put them along
    /// the bottom: an iPhone Duo folded, whose bars stand in the strip beside
    /// its camera. Nil everywhere else.
    var barEdge: HorizontalEdge? {
        #if os(iOS)
        if #available(iOS 27.1, *) { return toolbarVerticalEdge }
        #endif
        return nil
    }
}

extension View {
    /// A page's sides run under the screen's edges, so rows reach the edge:
    /// except beside an iPhone Duo's camera strip, where its bars stand
    /// (`barEdge`). Only the edges change, so folding and unfolding don't
    /// rebuild the page.
    func pageSides(_ enabled: Bool = true, also more: Edge.Set = []) -> some View {
        modifier(PageSides(enabled: enabled, more: more))
    }

    /// A row that won't fit a phone's width scrolls sideways there instead of
    /// pushing the whole page wider than the screen.
    /// A page taller than a phone's screen scrolls there.
    @ViewBuilder
    func scrollsVertically(_ when: Bool) -> some View {
        if when {
            ScrollView(.vertical, showsIndicators: false) { self }
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollsSideways(_ when: Bool) -> some View {
        if when {
            ScrollView(.horizontal, showsIndicators: false) { self }
        } else {
            self
        }
    }
}

/// An arrow on the remote, in a form that exists on iPad too.
enum RemoteArrow { case up, down, left, right }

// The tvOS-only pieces of SwiftUI the screens lean on, under names that build
// on iPad too. On the Apple TV each is the system's own; on iPad, where there
// is a finger instead of a focus engine, each is what touch needs in its place.

extension View {
    /// A region the focus engine treats as one, so a press toward it lands
    /// inside. Touch has no such thing.
    @ViewBuilder
    func tvFocusSection() -> some View {
        #if os(tvOS)
        focusSection()
        #else
        self
        #endif
    }

    /// The remote's Back button. On iPad, going back is the navigation bar's
    /// or a screen's own close button, so this does nothing there.
    @ViewBuilder
    func tvExitCommand(perform action: (() -> Void)?) -> some View {
        #if os(tvOS)
        onExitCommand(perform: action)
        #else
        self
        #endif
    }

    /// The remote's arrows, pressed while something here has focus. Touch
    /// moves by tapping where it wants to go, so nothing arrives on iPad.
    @ViewBuilder
    func tvMoveCommand(perform action: @escaping (RemoteArrow) -> Void) -> some View {
        #if os(tvOS)
        onMoveCommand { direction in
            switch direction {
            case .up: action(.up)
            case .down: action(.down)
            case .left: action(.left)
            case .right: action(.right)
            @unknown default: break
            }
        }
        #else
        self
        #endif
    }

    /// On a Mac, a text field without the system's sunken border, which showed inside
    /// `touchField`'s own.
    @ViewBuilder
    private var plainOnMac: some View {
        #if os(macOS)
        textFieldStyle(.plain)
        #else
        self
        #endif
    }

    /// A text field a finger can see: on the Apple TV the focus engine draws
    /// the field, but on iPad a bare field reads as a line of grey text.
    @ViewBuilder
    func touchField() -> some View {
        #if os(tvOS)
        self
        #else
        plainOnMac
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.14), lineWidth: 1))
        #endif
    }
}

extension View {
    /// The pointer over it, on a Mac: a little brighter, and lifted by `lift`. A Mac has
    /// no focus to show what a click would take, as the TV has, and no finger, as the
    /// iPad has; without this nothing answered the pointer at all.
    @ViewBuilder
    func pointerHover(lift: CGFloat = 1) -> some View {
        #if os(macOS)
        modifier(MacPointerHover(lift: lift))
        #else
        self
        #endif
    }

    /// A row under the pointer, on a Mac: a faint wash behind it, as a Mac's lists have.
    @ViewBuilder
    func pointerWash(cornerRadius: CGFloat) -> some View {
        #if os(macOS)
        modifier(MacPointerWash(cornerRadius: cornerRadius))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct MacPointerHover: ViewModifier {
    let lift: CGFloat
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .brightness(over ? 0.07 : 0)
            .scaleEffect(over ? lift : 1)
            .animation(.easeOut(duration: 0.12), value: over)
            .onHover { over = $0 }
    }
}

private struct MacPointerWash: ViewModifier {
    let cornerRadius: CGFloat
    @State private var over = false

    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: cornerRadius).fill(.white.opacity(over ? 0.08 : 0)))
            .animation(.easeOut(duration: 0.1), value: over)
            .onHover { over = $0 }
    }
}
#endif

#if os(tvOS)
extension PrimitiveButtonStyle where Self == CardButtonStyle {
    /// The Apple TV's lifting card, which on iPad is `TouchCardButtonStyle`.
    static var tvCard: CardButtonStyle { .card }
}
#else
/// A card that dips a little under the finger, in place of the Apple TV's lift.
struct TouchCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .pointerHover(lift: 1.02)
    }
}

extension ButtonStyle where Self == TouchCardButtonStyle {
    static var tvCard: TouchCardButtonStyle { TouchCardButtonStyle() }
}
#endif

#if os(iOS)
/// The app's own window, for what used to ask the whole screen: on an
/// iPhone Duo it's the open screen or the folded one, and in Split View only
/// part of either. Not the car's window, nor a second one in the background.
@MainActor
enum AppWindow {
    static var current: UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.session.role == .windowApplication }
        let scene = scenes.first { $0.activationState == .foregroundActive }
            ?? scenes.first { $0.activationState == .foregroundInactive } ?? scenes.first
        return scene?.keyWindow ?? scene?.windows.first
    }

    static var size: CGSize { current?.bounds.size ?? UIScreen.main.bounds.size }
    static var scale: CGFloat { current?.traitCollection.displayScale ?? UIScreen.main.scale }
}
#endif

private struct PageSides: ViewModifier {
    /// Off, the page keeps to the safe area (a phone's width, for some).
    let enabled: Bool
    /// Other edges the page runs under besides its sides.
    let more: Edge.Set
    @Environment(\.barEdge) private var barEdge

    func body(content: Content) -> some View {
        content.ignoresSafeArea(.container, edges: enabled ? sides.union(more) : [])
    }

    private var sides: Edge.Set {
        switch barEdge {
        case .leading: .trailing
        case .trailing: .leading
        case nil: .horizontal
        }
    }
}
