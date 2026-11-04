#if os(macOS)
import AppKit
import AVKit
import IOKit.pwr_mgt
import SwiftUI

// UIKit's names for what the shared code uses, on the Mac, where AppKit has the same
// things under other names: pictures, colours, fonts, views and the bridge that puts a
// view into SwiftUI, and the parts of the app object the shared code asks about. Where
// the platforms differ in what they mean (windows, the screen, scenes), the shared code
// says what the Mac does itself, under `#if os(macOS)`.

typealias UIImage = NSImage
typealias UIColor = NSColor
typealias UIFont = NSFont
typealias UIView = NSView
typealias UIEdgeInsets = NSEdgeInsets

// MARK: - Pictures

extension NSImage {
    /// UIKit's `UIImage(cgImage:)`: the picture at its pixel size.
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// UIKit's `cgImage`: the bitmap behind the picture, at its full size.
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    /// A Mac picture is drawn at its point size whatever the screen; UIKit's scale is 1 here.
    var scale: CGFloat { 1 }

    func jpegData(compressionQuality: CGFloat) -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: compressionQuality])
    }

    func pngData() -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

// MARK: - Views

extension NSView {
    /// UIKit's background colour: the view's layer, made when first asked for.
    @objc var backgroundColor: NSColor? {
        get { layer?.backgroundColor.flatMap(NSColor.init(cgColor:)) }
        set { wantsLayer = true; layer?.backgroundColor = newValue?.cgColor }
    }

    /// UIKit's clipping switch.
    var clipsToBounds: Bool {
        get { layer?.masksToBounds ?? false }
        set { wantsLayer = true; layer?.masksToBounds = newValue }
    }

    var isUserInteractionEnabled: Bool {
        get { true }
        set { }
    }

    /// UIKit's "lay me out again", for views that are told to.
    func setNeedsLayout() { needsLayout = true }
    func layoutIfNeeded() { layoutSubtreeIfNeeded() }
}

extension NSView {
    /// UIKit's opacity.
    var alpha: CGFloat {
        get { alphaValue }
        set { alphaValue = newValue }
    }

    /// UIKit's animation block: what changes inside it is animated, layout included.
    static func animate(withDuration duration: TimeInterval, animations: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            context.allowsImplicitAnimation = true
            animations()
        }, completionHandler: { completion?(true) })
    }
}

/// UIKit's label: a text field that can't be edited, selected or seen as a box.
class UILabel: NSTextField {
    init() {
        super.init(frame: .zero)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byWordWrapping
        cell?.wraps = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Lines at most; 0 for as many as the words need.
    var numberOfLines: Int {
        get { maximumNumberOfLines }
        set { maximumNumberOfLines = newValue }
    }

    var textAlignment: NSTextAlignment {
        get { alignment }
        set { alignment = newValue }
    }

    var text: String? {
        get { stringValue }
        set { stringValue = newValue ?? "" }
    }

    var attributedText: NSAttributedString? {
        get { attributedStringValue }
        set { attributedStringValue = newValue ?? NSAttributedString() }
    }
}

extension NSView.AutoresizingMask {
    static var flexibleWidth: Self { .width }
    static var flexibleHeight: Self { .height }
}

/// UIKit's bridge for putting a view in SwiftUI, on AppKit's: the shared code's
/// `makeUIView` / `updateUIView` stand for AppKit's `makeNSView` / `updateNSView`.
protocol UIViewRepresentable: NSViewRepresentable where NSViewType == UIViewType {
    associatedtype UIViewType: NSView
    associatedtype NSViewType = UIViewType
    associatedtype Coordinator = Void
    @MainActor func makeUIView(context: Context) -> UIViewType
    @MainActor func updateUIView(_ uiView: UIViewType, context: Context)
    @MainActor static func dismantleUIView(_ uiView: UIViewType, coordinator: Coordinator)
}

@MainActor
extension UIViewRepresentable {
    func makeNSView(context: Context) -> UIViewType { makeUIView(context: context) }
    func updateNSView(_ nsView: UIViewType, context: Context) { updateUIView(nsView, context: context) }
    static func dismantleNSView(_ nsView: UIViewType, coordinator: Coordinator) { dismantleUIView(nsView, coordinator: coordinator) }
    static func dismantleUIView(_ uiView: UIViewType, coordinator: Coordinator) {}
}

// MARK: - View controllers

typealias UIViewController = NSViewController

/// UIKit's bridge for putting a view controller in SwiftUI, on AppKit's.
protocol UIViewControllerRepresentable: NSViewControllerRepresentable where NSViewControllerType == UIViewControllerType {
    associatedtype UIViewControllerType: NSViewController
    associatedtype NSViewControllerType = UIViewControllerType
    associatedtype Coordinator = Void
    @MainActor func makeUIViewController(context: Context) -> UIViewControllerType
    @MainActor func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context)
    @MainActor static func dismantleUIViewController(_ uiViewController: UIViewControllerType, coordinator: Coordinator)
}

@MainActor
extension UIViewControllerRepresentable {
    func makeNSViewController(context: Context) -> UIViewControllerType { makeUIViewController(context: context) }
    func updateNSViewController(_ nsViewController: UIViewControllerType, context: Context) {
        updateUIViewController(nsViewController, context: context)
    }
    static func dismantleNSViewController(_ nsViewController: UIViewControllerType, coordinator: Coordinator) {
        dismantleUIViewController(nsViewController, coordinator: coordinator)
    }
    static func dismantleUIViewController(_ uiViewController: UIViewControllerType, coordinator: Coordinator) {}
}

/// AVKit's player screen as the iPhone has it, on the Mac's player view: the picture,
/// how it fills the view, and the view over the picture where the app draws subtitles.
/// The app draws its own controls (PlayerChrome), so the Mac's stay away.
final class AVPlayerViewController: NSViewController {
    let playerView = AVPlayerView()

    override func loadView() {
        playerView.controlsStyle = .none
        playerView.wantsLayer = true
        view = playerView
    }

    var player: AVPlayer? {
        get { playerView.player }
        set { playerView.player = newValue }
    }

    var showsPlaybackControls: Bool {
        get { playerView.controlsStyle != .none }
        set { playerView.controlsStyle = newValue ? .inline : .none }
    }

    var videoGravity: AVLayerVideoGravity {
        get { playerView.videoGravity }
        set { playerView.videoGravity = newValue }
    }

    var contentOverlayView: NSView? {
        loadViewIfNeeded()
        return playerView.contentOverlayView
    }

    var allowsPictureInPicturePlayback: Bool {
        get { playerView.allowsPictureInPicturePlayback }
        set { playerView.allowsPictureInPicturePlayback = newValue }
    }
}

// MARK: - SwiftUI's iPhone-only modifiers

extension View {
    /// The iPhone's full-screen cover: on the Mac, a sheet the size of the window it covers, so
    /// it fills the window as a cover fills the iPhone's screen (Live TV's full screen, Now
    /// Playing, the app's panels), and closes as a cover does (dismiss, Escape). A film has a
    /// window of its own instead (MacPlayerStage).
    func fullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                        @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { MacCover(content: content) }
    }

    func fullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                            @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { item in MacCover { content(item) } }
    }

    /// A Mac window's title is always the small one.
    func navigationBarTitleDisplayMode(_ mode: MacTitleDisplayMode) -> some View { self }

    /// A Mac's text fields don't capitalize as you type; nothing to switch off.
    func textInputAutocapitalization(_ autocapitalization: TextInputAutocapitalization?) -> some View { self }
}

enum MacTitleDisplayMode { case automatic, inline, large }

/// A cover's content at the size of the window it covers, as that was when it opened.
private struct MacCover<Content: View>: View {
    let content: () -> Content
    @State private var size = AppWindow.size

    var body: some View {
        content()
            .buttonStyle(.borderless)
            .frame(width: max(size.width, 640), height: max(size.height, 400))
    }
}

struct TextInputAutocapitalization {
    static let never = Self(), words = Self(), sentences = Self(), characters = Self()
}

// MARK: - The device

/// What the shared code asks of the device: what to call it and what it runs.
final class UIDevice: Sendable {
    static let current = UIDevice()

    var model: String { "Mac" }
    var systemName: String { "macOS" }
    var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return v.patchVersion > 0 ? "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)" : "\(v.majorVersion).\(v.minorVersion)"
    }
    /// The Mac's own name, as Sharing settings has it.
    var name: String { Host.current().localizedName ?? "Mac" }

    enum Idiom { case phone, pad, tv, mac, unspecified }
    var userInterfaceIdiom: Idiom { .mac }
}

// MARK: - The app

/// UIKit's background-task token; the Mac doesn't suspend an app that's out of sight.
struct UIBackgroundTaskIdentifier: Equatable, Sendable {
    let rawValue: Int
    static let invalid = UIBackgroundTaskIdentifier(rawValue: 0)
}

/// The parts of UIKit's app object the shared code asks about, as a Mac app has them.
@MainActor
final class UIApplication {
    static let shared = UIApplication()

    enum State { case active, inactive, background }

    /// In the background means hidden; a Mac app in another app's shadow is only inactive.
    var applicationState: State {
        NSApp.isHidden ? .background : (NSApp.isActive ? .active : .inactive)
    }

    nonisolated static let didEnterBackgroundNotification = NSApplication.didHideNotification
    nonisolated static let willEnterForegroundNotification = NSApplication.willUnhideNotification
    nonisolated static let didBecomeActiveNotification = NSApplication.didBecomeActiveNotification
    nonisolated static let willResignActiveNotification = NSApplication.willResignActiveNotification

    func open(_ url: URL, options: [String: Any] = [:], completionHandler: ((Bool) -> Void)? = nil) {
        let opened = NSWorkspace.shared.open(url)
        completionHandler?(opened)
    }

    @discardableResult
    func open(_ url: URL) async -> Bool { NSWorkspace.shared.open(url) }

    func canOpenURL(_ url: URL) -> Bool { NSWorkspace.shared.urlForApplication(toOpen: url) != nil }

    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)? = nil) -> UIBackgroundTaskIdentifier { .invalid }
    func endBackgroundTask(_ identifier: UIBackgroundTaskIdentifier) {}

    /// While something plays, the display isn't let go to sleep.
    private var sleepAssertion: IOPMAssertionID = 0
    var isIdleTimerDisabled: Bool {
        get { sleepAssertion != 0 }
        set {
            if newValue, sleepAssertion == 0 {
                IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                            IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                            "JellyGoose is playing" as CFString, &sleepAssertion)
            } else if !newValue, sleepAssertion != 0 {
                IOPMAssertionRelease(sleepAssertion)
                sleepAssertion = 0
            }
        }
    }

    /// A Mac app can't change the icon Finder and Launchpad show (it's the one in the
    /// bundle), but it can change its Dock icon while it runs: the chosen icon is kept
    /// here and put in the Dock at every launch. Its image is `dock-<name>`, the iPhone's
    /// artwork in the Mac's shape (macOS/Assets.xcassets/Dock Icons).
    private static let dockIconKey = "goosetv.macDockIcon"
    var alternateIconName: String? { UserDefaults.standard.string(forKey: Self.dockIconKey) }
    var supportsAlternateIcons: Bool { true }
    func setAlternateIconName(_ name: String?) async throws {
        UserDefaults.standard.set(name, forKey: Self.dockIconKey)
        Self.showDockIcon()
    }

    /// The chosen icon in the Dock, or the bundle's own (nil puts it back).
    static func showDockIcon() {
        NSApplication.shared.applicationIconImage = UserDefaults.standard.string(forKey: dockIconKey)
            .flatMap { NSImage(named: "dock-\($0)") }
    }
}
#endif
