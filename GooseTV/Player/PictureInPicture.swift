import SwiftUI
import AVKit
import Combine
#if os(iOS)
import AetherEngine
#endif

// MARK: - Closing the player

private struct PlayerCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    /// How the player closes where it wasn't presented as a cover: on iPhone
    /// and iPad it's shown on a stage of its own (see `PlayerStage`), which a
    /// view's own `dismiss` knows nothing of. Nil elsewhere.
    var playerClose: (() -> Void)? {
        get { self[PlayerCloseKey.self] }
        set { self[PlayerCloseKey.self] = newValue }
    }
}

extension View {
    /// Shows the player for whatever `item` holds. On the Apple TV it's a
    /// cover over the screen that asked. On iPhone and iPad the player goes
    /// on a stage over the whole app instead, so that a film shrunk to
    /// picture in picture can leave the app in reach beneath it and still be
    /// the same player when it's brought back.
    ///
    /// A recording the server is still making isn't a film yet: its file
    /// has no end. It's shown as the television it is, on its channel's
    /// full screen from the recording's beginning (see `LiveRecording`).
    func playerCover(item: Binding<BaseItem?>, @ViewBuilder player: @escaping (BaseItem) -> PlayerView) -> some View {
        modifier(PlayerCover(item: item, player: player))
    }

    @ViewBuilder
    fileprivate func filmCover(item: Binding<BaseItem?>, player: @escaping (BaseItem) -> PlayerView) -> some View {
        #if os(iOS)
        modifier(StagedPlayer(item: item, player: player))
        #elseif os(macOS)
        modifier(MacStagedPlayer(item: item, player: player))
        #else
        fullScreenCover(item: item, content: player)
        #endif
    }
}

private struct PlayerCover: ViewModifier {
    @Binding var item: BaseItem?
    let player: (BaseItem) -> PlayerView
    @Environment(\.appState) private var app
    /// Playing needs the trial or the unlock (see `Unlock`); a film asked
    /// for without either brings up the unlock screen instead, and plays if
    /// it's unlocked there.
    @ObservedObject private var unlock = Unlock.shared
    /// Recordings found to have ended since they were listed as under way:
    /// films, from then on.
    @State private var ended: Set<String> = []

    private func isUnderWay(_ item: BaseItem) -> Bool { item.isBeingRecorded && !ended.contains(item.id) }

    func body(content: Content) -> some View {
        content
            .onChange(of: item?.id) { _, _ in
                guard let wanted = item, !unlock.mayPlay else { return }
                let asked = $item
                asked.wrappedValue = nil
                unlock.ask { asked.wrappedValue = wanted }
            }
            .filmCover(item: Binding(get: { item.flatMap { isUnderWay($0) || !unlock.mayPlay ? nil : $0 } }, set: { item = $0 }), player: player)
            // From a view of its own: two covers on the one view aren't to
            // be relied on.
            .background {
                Color.clear.fullScreenCover(item: Binding(get: { item.flatMap { isUnderWay($0) && unlock.mayPlay ? $0 : nil } }, set: { item = $0 })) { recording in
                    if let client = app?.client {
                        LiveWatchHost(channel: recording, client: client) {
                            // Over, as it turns out: asked for again a moment
                            // after this has gone, as the film it is by now.
                            item = nil
                            Task {
                                try? await Task.sleep(for: .milliseconds(700))
                                ended.insert(recording.id)
                                item = recording
                            }
                        }
                    }
                }
            }
    }
}

#if os(iOS)
private struct StagedPlayer: ViewModifier {
    @Binding var item: BaseItem?
    let player: (BaseItem) -> PlayerView
    @EnvironmentObject private var app: AppState

    func body(content: Content) -> some View {
        content.onChange(of: item?.id) { _, _ in
            guard let item else { return }
            let asked = $item
            // Let go of as the player closes, and as it shrinks: from then
            // the screen that asked is free to ask for something else.
            PlayerStage.shared.open(player(item), id: item.id, app: app) { asked.wrappedValue = nil }
        }
    }
}

// MARK: - The stage

/// Where the player is shown on iPhone and iPad: a window of its own over
/// the app's. A cover belongs to the screen that presented it and goes when
/// it's dismissed, player and all; here the player can be put out of sight
/// while its film plays on in a picture-in-picture window, the app beneath
/// in full use, and be brought back as it was.
@MainActor
final class PlayerStage {
    static let shared = PlayerStage()
    /// Posted to have the player close itself the way its own button does,
    /// filing where the film got to: the picture-in-picture window was closed.
    static let closeAsked = Notification.Name("goosetv.player.closeAsked")

    private var window: UIWindow?
    /// The film on the stage.
    private var playing: String?
    private var whenGone: (() -> Void)?
    /// Out of sight, with its film in a picture-in-picture window.
    private(set) var shrunk = false
    /// On the car's screen (see `CarScreenSceneDelegate`) rather than the
    /// phone's: the film goes on as sound when the app is in the background.
    private(set) var onCarScreen = false

    func open(_ player: PlayerView, id: String, app: AppState, whenGone: @escaping () -> Void) {
        // The film in the small window, asked for again: that one, full size.
        if playing == id, shrunk {
            self.whenGone = whenGone
            PlayerPiP.shared.stop()
            return
        }
        strike()
        guard let scene = Self.scene else { return whenGone() }
        // On the car's screen, a channel playing there stops for the film.
        if scene.isCarScreen { CarScreenModel.shared?.stopChannel() }
        onCarScreen = scene.isCarScreen
        let stage = UIWindow(windowScene: scene)
        let shown = player
            .overlay { if scene.isCarScreen, let car = CarScreenModel.shared { CarDrivingCover(car: car) } }
            .environment(\.playerClose, { [weak self] in self?.close() } as (() -> Void)?)
            // What the app's own window is given at its root.
            .environmentObject(app)
            .environment(\.appState, app)
            .themed(app.shownTheme)
            .preferredColorScheme(.dark)
            .font(.app(29))
        // The car's screen is half a phone's: the player laid out at a
        // phone's size and shrunk to fit beside CarPlay's own column.
        let room = scene.windows.first { !$0.isHidden }?.safeAreaInsets ?? .zero
        let host = UIHostingController(rootView: scene.isCarScreen ? AnyView(CarFit(clear: room) { shown }) : AnyView(shown))
        // There it's placed clear of CarPlay's column by `CarFit` itself: a
        // player laid out at twice its room misreads where the column is.
        if scene.isCarScreen { host.safeAreaRegions = [] }
        host.view.backgroundColor = .black
        stage.rootViewController = host
        stage.windowLevel = .normal + 1
        stage.overrideUserInterfaceStyle = .dark
        stage.alpha = 0
        stage.makeKeyAndVisible()
        UIView.animate(withDuration: 0.25) { stage.alpha = 1 }
        window = stage
        playing = id
        shrunk = false
        self.whenGone = whenGone
    }

    /// The film is done with.
    func close() {
        guard let stage = window else { return }
        let gone = whenGone
        window = nil
        playing = nil
        whenGone = nil
        shrunk = false
        Self.appWindow(besides: stage)?.makeKey()
        UIView.animate(withDuration: 0.25) {
            stage.alpha = 0
        } completion: { _ in
            stage.isHidden = true
            stage.rootViewController = nil
        }
        gone?()
    }

    /// The film has gone to its small window: the player stays as it is,
    /// out of sight and out of the way of a finger, and the app is back in
    /// use. Not hidden, which would tell the player's views they had gone,
    /// and they stop their film when they go.
    func shrink() {
        guard let stage = window, !shrunk else { return }
        shrunk = true
        stage.alpha = 0
        stage.isUserInteractionEnabled = false
        Self.appWindow(besides: stage)?.makeKey()
        let gone = whenGone
        whenGone = nil
        gone?()
    }

    /// Back from the small window.
    func restore() {
        guard let stage = window, shrunk else { return }
        shrunk = false
        stage.isUserInteractionEnabled = true
        stage.makeKeyAndVisible()
        UIView.animate(withDuration: 0.2) { stage.alpha = 1 }
    }

    /// The small window was closed with the film still in it.
    func askToClose() {
        guard window != nil else { return }
        NotificationCenter.default.post(name: Self.closeAsked, object: nil)
    }

    /// Takes the stage down at once, for the next film to go up.
    private func strike() {
        guard let stage = window else { return }
        window = nil
        playing = nil
        shrunk = false
        let gone = whenGone
        whenGone = nil
        stage.isHidden = true
        stage.rootViewController = nil
        gone?()
    }

    /// The phone's screen, or the car's where JellyGoose is open on it: a
    /// film started on the phone then plays on the car's screen, as one
    /// chosen there does. Which screen was taken used to be chance (the
    /// first scene found), and so a film went to the car only some days.
    private static var scene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let car = scenes.first(where: { $0.isCarScreen && $0.activationState != .background }) { return car }
        let phone = scenes.filter { !$0.isCarScreen }
        // The app's own window, not a second one that only says where the
        // app is (OneWindowGate).
        if let main = OneWindow.mainScene, phone.contains(main) { return main }
        return phone.first { $0.activationState == .foregroundActive } ?? phone.first
    }

    private static func appWindow(besides stage: UIWindow) -> UIWindow? {
        stage.windowScene?.windows.first { $0 !== stage && !$0.isHidden }
    }
}

// MARK: - Picture in picture

/// The film in the system's small window. One film at a time, whichever
/// player has it: Apple's and AetherEngine's hand over a picture the system
/// can take, VLC's has none it can, so there the button isn't offered.
///
/// As the window opens the player's stage goes out of sight (`PlayerStage`)
/// and the app is in use again; the window's own button, or turning the
/// device on its side, brings the player back; its close button ends the film.
@MainActor
final class PlayerPiP: NSObject, ObservableObject {
    static let shared = PlayerPiP()

    /// Whether what's playing can be shrunk now.
    @Published private(set) var isPossible = false
    @Published private(set) var isActive = false

    private var controller: AVPictureInPictureController?
    private var possible: NSKeyValueObservation?
    private weak var owner: AnyObject?
    private weak var layer: CALayer?
    private var samples: SampleSource?
    /// Told as the window opens and closes: AetherEngine keeps its picture
    /// coming for the window, which nothing else is asking it for.
    private var onActive: ((Bool) -> Void)?
    /// The window is closing because its own button asked for the player back.
    private var restoring = false
    /// How the device was last held, of the ways that count.
    private var held: UIDeviceOrientation = .portrait

    private override init() {
        super.init()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(forName: UIDevice.orientationDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.turned() }
        }
    }

    /// A player's picture, as a layer of Apple's player.
    func attach(playerLayer: AVPlayerLayer, owner: AnyObject, onActive: ((Bool) -> Void)? = nil) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), layer !== playerLayer else { return }
        detach(owner: self.owner)
        guard let made = AVPictureInPictureController(playerLayer: playerLayer) else { return }
        samples = nil
        adopt(made, layer: playerLayer, owner: owner, onActive: onActive)
    }

    /// A player's picture, as the frames AetherEngine decodes itself.
    func attach(sampleBuffer source: SoftwarePiPSource, owner: AnyObject, onActive: ((Bool) -> Void)? = nil) {
        guard AVPictureInPictureController.isPictureInPictureSupported(), layer !== source.layer else { return }
        detach(owner: self.owner)
        let answers = SampleSource(source: source)
        samples = answers
        adopt(AVPictureInPictureController(contentSource: .init(sampleBufferDisplayLayer: source.layer, playbackDelegate: answers)),
              layer: source.layer, owner: owner, onActive: onActive)
    }

    private func adopt(_ made: AVPictureInPictureController, layer: CALayer, owner: AnyObject, onActive: ((Bool) -> Void)?) {
        made.delegate = self
        // Leaving the app mid-film carries on in the small window.
        made.canStartPictureInPictureAutomaticallyFromInline = true
        controller = made
        self.layer = layer
        self.owner = owner
        self.onActive = onActive
        possible = made.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] made, _ in
            let can = made.isPictureInPicturePossible
            Task { @MainActor in
                guard let self, self.controller === made, self.isPossible != can else { return }
                self.isPossible = can
            }
        }
    }

    /// The player's picture is going: its film ended, or the player closed.
    func detach(owner: AnyObject?) {
        guard let owner, owner === self.owner else { return }
        let wasActive = isActive
        possible = nil
        controller?.delegate = nil
        controller = nil
        samples = nil
        layer = nil
        self.owner = nil
        if isPossible { isPossible = false }
        if wasActive {
            isActive = false
            onActive?(false)
            // The film ended in its small window, with the player still up
            // behind it (what's next is asked there): back to the player.
            PlayerStage.shared.restore()
        }
        onActive = nil
    }

    func start() { controller?.startPictureInPicture() }

    /// Closes the small window by way of bringing the player back.
    func stop() { controller?.stopPictureInPicture() }

    /// Turned on its side with the film in its small window: the film fills
    /// the screen, as it would have on its side to begin with.
    private func turned() {
        let now = UIDevice.current.orientation
        guard now.isPortrait || now.isLandscape else { return }
        defer { held = now }
        if isActive, now.isLandscape, held.isPortrait, UIApplication.shared.applicationState == .active { stop() }
    }

    /// How the device is held as the small window opens. Lying flat it
    /// doesn't say, and was taken to be upright: an iPad on a table, laid
    /// out on its side, had its film fill the screen again the moment it
    /// was picked up. Flat, it's held the way the screen is laid out.
    private func noteHold() {
        let device = UIDevice.current.orientation
        if device.isPortrait || device.isLandscape {
            held = device
        } else {
            let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive }
            held = scene?.interfaceOrientation.isLandscape == true ? .landscapeLeft : .portrait
        }
    }
}

extension PlayerPiP: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isActive = true
            onActive?(true)
            noteHold()
            PlayerStage.shared.shrink()
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated {
            restoring = true
            PlayerStage.shared.restore()
            completionHandler(true)
        }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isActive = false
            onActive?(false)
            // Closed by its own close button, not asked back: the film's over.
            if !restoring { PlayerStage.shared.askToClose() }
            restoring = false
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            isActive = false
            onActive?(false)
        }
    }
}

/// What the small window asks of a film AetherEngine is decoding itself:
/// where it is, whether it's playing, and its own play, pause and skip.
private final class SampleSource: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let source: SoftwarePiPSource

    init(source: SoftwarePiPSource) { self.source = source }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, setPlaying playing: Bool) {
        MainActor.assumeIsolated { source.setPlaying(playing) }
    }

    func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated { source.timeRange() }
    }

    func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { source.isPaused }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated { source.skip(by: skipInterval.seconds) }
        completionHandler()
    }
}

/// A second layer of Apple's player, under the one the film is seen in. The
/// small window is started from a layer, by a button of the app's own; the
/// player's view controller would only start one from its own controls,
/// which the app's stand in for.
struct PiPLayerSurface: UIViewRepresentable {
    let player: AVPlayer
    /// Whose picture this is, to let go of it by.
    let owner: AnyObject

    final class Holder {
        weak var owner: AnyObject?
    }

    func makeCoordinator() -> Holder { Holder() }

    func makeUIView(context: Context) -> PiPLayerView {
        let view = PiPLayerView()
        view.backgroundColor = .black
        view.isUserInteractionEnabled = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        context.coordinator.owner = owner
        PlayerPiP.shared.attach(playerLayer: view.playerLayer, owner: owner)
        return view
    }

    func updateUIView(_ view: PiPLayerView, context: Context) {}

    static func dismantleUIView(_ view: PiPLayerView, coordinator: Holder) {
        PlayerPiP.shared.detach(owner: coordinator.owner)
        view.playerLayer.player = nil
    }
}

final class PiPLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}
#endif
