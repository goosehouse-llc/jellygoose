import SwiftUI

extension PlayerEngine {
    /// Only VLC can work on the sound (see `AudioClarity`).
    var soundModes: Bool { false }

    /// The subtitle first: an engine that rebuilds its stream for other audio
    /// keeps the subtitle on through it.
    func selectTracks(audio: String, subtitle: String) {
        selectSubtitle(subtitle)
        selectAudio(audio)
    }
}

/// What the app's own player controls need from whichever engine is playing.
/// Times are the film's own, in seconds, whatever the stream counts from.
@MainActor
protocol PlayerEngine: ObservableObject {
    var item: BaseItem { get }
    var position: Double { get }
    var duration: Double { get }
    var isPlaying: Bool { get }
    var isLoading: Bool { get }
    /// The intro or credits the film is inside now, if the server marked any.
    var activeSkip: SkipSegment? { get }
    var rate: Float { get }
    var trackList: TrackList { get }
    /// How far a subtitle the app draws is shifted, or nil when none is drawn.
    var subtitleDelay: Double? { get }
    /// How far the sound is moved against the picture, later being positive,
    /// or nil when this engine can't move it.
    var audioDelay: Double? { get }

    func togglePause()
    /// Jumps there and plays on, paused or not.
    func seek(toFilmSeconds seconds: Double)
    func skip(_ seconds: Int32)
    func setRate(_ rate: Float)
    func selectAudio(_ id: String)
    func selectSubtitle(_ id: String)
    /// Both at once: the audio, and the subtitle that goes with it.
    func selectTracks(audio: String, subtitle: String)
    /// Whether Dialogue Boost works here.
    var soundModes: Bool { get }
    func setSubtitleDelay(_ seconds: Double)
    /// Moves the sound against the picture, and remembers it for the title.
    func setAudioDelay(_ seconds: Double)
    /// Where working the sound's place out from the subtitles has got to, or
    /// nil when this engine can't try or no subtitle is on to go by.
    var audioSyncDetection: AudioSyncDetection? { get }
    /// Starts working it out as the film plays; while it's listening, stops.
    func detectAudioSync()
    /// The controls have come up or gone away, for subtitles that need to
    /// move out of their way.
    func controlsShown(_ shown: Bool)
    /// Which version of the film is playing, where it's kept in more than one.
    var mediaSourceId: String? { get }
    /// Whether a subtitle found on the internet can be shown here. Not over a
    /// download playing from the device, which the server has no part in.
    var takesFoundSubtitles: Bool { get }
    /// Lists a subtitle the server has just been given for this film and
    /// turns it on, with the film playing on.
    func show(_ found: FoundSubtitle)
    /// What's playing and how its stream was settled, for the stats panel.
    var playbackContext: PlaybackContext? { get }
    /// What the player can say about how the film is going right now.
    func liveStats() -> LiveStats
}

/// Told when the controls skip the credits without being asked, so that
/// what's next isn't asked about either.
private struct CreditsSkippedKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}

extension EnvironmentValues {
    var creditsSkipped: (() -> Void)? {
        get { self[CreditsSkippedKey.self] }
        set { self[CreditsSkippedKey.self] = newValue }
    }
}

/// What the controls remember about skipping for as long as one film plays.
/// Kept by the player and not by them: they are built again whenever the
/// stream is (a change of track on a converted film, a stall put right), and
/// what was skipped or gone back into before is still so afterwards.
final class SkipMemory {
    /// When the viewer last moved through the film themselves. An intro they
    /// land in is one they went to, so it's offered rather than skipped.
    var movedAt = Date.distantPast
    /// The segments skipped without asking, each the once: going back into
    /// one is a wish to see it.
    var skipped: Set<String> = []
    /// When the film was first seen playing. Until then and for a moment
    /// after, wherever it is is where it was left, and nowhere anyone went.
    var openedAt: Date?
}

private struct SkipMemoryKey: EnvironmentKey {
    static let defaultValue: SkipMemory? = nil
}

extension EnvironmentValues {
    var skipMemory: SkipMemory? {
        get { self[SkipMemoryKey.self] }
        set { self[SkipMemoryKey.self] = newValue }
    }
}

/// The clock, which moves several times a second. Announcing each move
/// redrew every control over the picture, hidden or not, all through a film;
/// so it is announced only while the controls are up, and read fresh whenever
/// asked otherwise.
struct PlayerClockState {
    private(set) var seconds: Double = 0
    private(set) var visible = true

    /// Whether the controls need telling about this move.
    mutating func move(to seconds: Double) -> Bool {
        self.seconds = seconds
        return visible
    }

    /// Whether the controls need telling now they've come up.
    mutating func show(_ shown: Bool) -> Bool {
        visible = shown
        return shown
    }
}

/// The controls over the picture, the same for both engines: the title, a row
/// of buttons for the tracks, speed and chapters, a timeline with the chapters
/// marked on it, a preview of where a scrub will land, and when the film will
/// end.
///
/// Remote: click or play/pause toggles. Left/right skip -10s/+30s while
/// playing and step while paused; held, they scrub, faster the longer they're
/// held; a swipe along the touch surface scrubs smoothly. While scrubbing,
/// click jumps to the mark and back cancels. Up takes an offered skip, or
/// else moves onto the row of buttons at Subtitles: left and right move along
/// it, select opens a button's menu, up and down move through the menu, and
/// back steps out. Down brings up a card about what's playing; down again,
/// up or back puts it away. Back puts the controls away, and closes the film from a
/// bare picture.
struct PlayerChrome<Engine: PlayerEngine>: View {
    @Environment(\.isNarrow) private var narrow
    @Environment(\.layoutDirection) private var layoutDirection
    /// The controls have the half below an iPhone Duo's fold (TabletopFold).
    @Environment(\.playerTabletop) private var tabletop
    #if os(iOS)
    @Environment(\.verticalSizeClass) private var verticalSize
    @ObservedObject private var pip = PlayerPiP.shared
    #endif
    @Environment(\.appState) private var app
    @ObservedObject var engine: Engine
    let chapters: [Chapter]
    /// The commercial breaks the server marked in a recording, for the timeline.
    var breaks: [SkipSegment] = []
    let trickplay: Trickplay?
    /// A word beside the title saying which engine is playing, when it matters.
    var badge: String? = nil
    let onClose: () -> Void

    /// Stats opens nothing: its button turns the panel of them on and off.
    /// The last two aren't buttons in the row: they open from the foot of
    /// Subtitles, and Back steps out to it.
    enum Menu: Hashable { case subtitles, audio, audioSync, sound, timing, speed, chapters, sleep, together, stats, findSubtitles, subtitleLanguage }
    /// Where the remote's presses are going. The picture keeps focus
    /// throughout; the row and its menus are highlights the presses move, so
    /// nothing ever has to hand focus back.
    enum Mode: Equatable { case picture, row, menu(Menu) }

    @State private var mode: Mode = .picture
    /// The highlighted button in the row, and the highlighted line in an
    /// open menu.
    @State private var rowIndex = 0
    @State private var menuIndex = 0
    /// A detected audio offset, while it's offered over the picture.
    @State private var offeredFix: Double?
    /// A sideways swipe along the row, carried until it's far enough to move.
    @State private var swipeCarry: CGFloat = 0
    /// The card a press down brings up: a still, the title and the plot.
    @State private var showingInfo = false
    @State private var overlayShown = true
    @State private var hideOverlay: Task<Void, Never>?
    /// Where the viewer is scrubbing to, in film seconds. Nil when not
    /// scrubbing. Nothing is sought until they commit to it: moving a mark and
    /// jumping once is kinder to a remote file than seeking on every press.
    @State private var scrubTarget: Double?
    /// Whether the film was playing when a scrub paused it, to play on if the
    /// scrub is cancelled.
    @State private var resumeAfterScrub = false
    /// What's remembered about skipping: the player's, or these controls'
    /// own where nothing above them keeps one.
    @Environment(\.skipMemory) private var keptSkips
    @State private var ownSkips = SkipMemory()
    private var skips: SkipMemory { keptSkips ?? ownSkips }
    /// Waiting to see the film play through a segment before skipping it.
    @State private var skipping: Task<Void, Never>?
    /// Where commercials were skipped from without asking, while the way back
    /// is offered: the marks are a detector's, which now and then takes the
    /// programme for a break.
    @State private var undoSkip: Double?
    @Environment(\.creditsSkipped) private var creditsSkipped
    /// Its button says how long is left, and redraws as it's set.
    @ObservedObject private var sleep = SleepTimer.shared
    /// Dialogue Boost, where VLC is playing.
    @ObservedObject private var clarity = AudioClarity.shared
    /// Watching together, where the server lets this account.
    @ObservedObject private var group = SyncPlay.shared
    /// What the film player lets the group do with it; nil on a channel.
    @Environment(\.watchTogether) private var togetherHooks
    /// Playing as the group says, while this device is in one.
    @State private var together: SyncPlayDriver?
    /// What another device's commands work while this player is open, by the
    /// id it's let go by (see `RemoteControl`).
    @State private var remoteToken: UUID?
    /// The server's groups, as last asked, to join from the menu.
    @State private var groupsListed: [SyncPlayGroupInfo] = []
    /// Looking for a subtitle on the internet, through the server.
    @State private var finding = Finding()
    /// The panel of facts about how the film is being played, and its lines
    /// as last read. Stays up with the controls gone: it's for watching.
    @State private var showingStats = PlaybackStats.shown
    @State private var statLines: [StatLine] = []

    /// Where a search for subtitles has got to.
    private struct Finding {
        /// The language being looked in; the account's, until another is chosen.
        var language: SubtitleLanguage?
        /// What came back. Nil while the server is still asking.
        var results: [RemoteSubtitle]?
        /// The search itself went wrong, as distinct from finding nothing.
        var failed = false
        /// The one chosen, while the server fetches it.
        var fetching: String?
        /// Why the last one chosen didn't arrive.
        var refused: String?
        var task: Task<Void, Never>?
        /// The fetch, apart from the search: looking in another language
        /// meanwhile doesn't call off what the server was already sent for.
        var fetch: Task<Void, Never>?
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            if engine.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            if controlsVisible {
                controls
                    .transition(.opacity)
            }

            if showingInfo {
                infoCard
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if undoSkip != nil, mode == .picture {
                // Taken already, and wrongly perhaps: up goes back to it.
                let words = String(localized: "Undo Skip", comment: "Offered over the picture for a few seconds after commercials in a recording were skipped automatically: goes back to where the skip began")
                offer(words, touchIcon: "arrow.uturn.backward",
                      spoken: String(localized: "\(words). Press up to go back.", comment: "Read out for the offer to undo an automatic skip. The placeholder is the offer, Undo Skip"),
                      take: takeUndo)
            } else if let skip = engine.activeSkip, mode == .picture {
                // Offered, not taken: up takes it.
                offer(skip.label, touchIcon: "forward.end.fill",
                      spoken: String(localized: "\(skip.label). Press up to skip.", comment: "Read out for a skip being offered over the picture (Skip Intro, Skip Credits, Skip Commercials). The placeholder is the offer")) {
                    jump(to: skip.end); showOverlay()
                }
            } else if let fix = offeredFix, mode == .picture {
                // What the detection found, offered the way a skip is: up takes it.
                let words = "\(title(for: .audioSync)): \(AudioSync.label(fix))"
                offer(words, touchIcon: "waveform",
                      spoken: String(localized: "\(words). Press up to use it.", comment: "Read out for the offer of a detected audio offset over the picture. The placeholder is the offer, like Audio Sync: 0.7 s Later"),
                      take: takeOfferedFix)
            }

            if showingStats, !statLines.isEmpty {
                // The top corner the title isn't in; under the AirPlay button
                // on a touch screen, which is.
                StatsPanel(lines: statLines)
                    .padding(.trailing, trailingMargin)
                    .padding(.top, topMargin + (isTouch ? 62 : 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            #if os(tvOS)
            // In front of everything and always holding focus, so every press
            // and swipe on the remote arrives here.
            surface
            #endif
        }
        #if !os(tvOS)
        // Under the controls on a touch screen, so a tap on a button reaches
        // the button and a tap anywhere else reaches the picture. The whole
        // screen, even when nothing else is showing.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { surface.accessibilityHidden(true) }
        #endif
        .animation(.easeOut(duration: 0.25), value: overlayShown)
        .animation(.easeOut(duration: 0.2), value: mode)
        .animation(.easeOut(duration: 0.25), value: showingInfo)
        .animation(.easeOut(duration: 0.2), value: engine.activeSkip)
        .animation(.easeOut(duration: 0.2), value: offeredFix)
        .animation(.easeOut(duration: 0.2), value: undoSkip)
        .animation(.easeOut(duration: 0.2), value: showingStats)
        .task(id: showingStats) { await followStats() }
        .onChange(of: engine.activeSkip, initial: true) { _, skip in
            skipping?.cancel()
            skipping = Task { await skipUnasked(skip) }
        }
        .onChange(of: engine.isPlaying && !engine.isLoading, initial: true) { _, playing in
            if playing, skips.openedAt == nil { skips.openedAt = Date() }
        }
        .onChange(of: engine.audioSyncDetection) { _, detection in
            // Found: offered over the picture for a while, and in the menu
            // for as long as it stands.
            guard case .found(let fix) = detection else { return offeredFix = nil }
            offeredFix = fix
            Task {
                try? await Task.sleep(for: .seconds(25))
                if offeredFix == fix { offeredFix = nil }
            }
        }
        .onAppear { showOverlay() }
        #if os(iOS)
        .onAppear { readInsets() }
        // Turned on its side, or back: the safe area moves with it, a moment
        // after the size changes.
        .onGeometryChange(for: CGSize.self) { $0.size } action: { _ in
            DispatchQueue.main.async { readInsets() }
        }
        #endif
        // Every scrubbing thumbnail, fetched while the film plays, and no
        // longer once the controls go (the player closing, the next episode).
        .task(priority: .utility) {
            guard let trickplay else { return }
            await TrickplaySheets.prefetch(trickplay.sheetURLs, near: trickplay.sheetIndex(at: engine.position))
        }
        .onDisappear { hideOverlay?.cancel(); finding.task?.cancel(); finding.fetch?.cancel(); skipping?.cancel() }
        .onChange(of: group.group?.groupId, initial: true) { _, id in followGroup(id) }
        .onDisappear { together?.detach() }
        .onAppear { remoteToken = RemoteControl.shared.attach(remoteControls) }
        .onDisappear { if let remoteToken { RemoteControl.shared.detach(remoteToken) } }
        .onChange(of: controlsVisible, initial: true) { _, visible in engine.controlsShown(visible) }
        #if os(macOS)
        // The menu bar's Controls menu, which reads whether the film is playing.
        .onChange(of: engine.isPlaying, initial: true) { _, playing in MacPlayerStage.shared.filmPlaying = playing }
        .onReceive(NotificationCenter.default.publisher(for: MacPlayerStage.playPauseAsked)) { _ in remoteActions.playPause() }
        .onReceive(NotificationCenter.default.publisher(for: MacPlayerStage.skipAsked)) { note in
            guard let seconds = note.object as? Int32 else { return }
            skip(by: seconds)
            showOverlay()
        }
        #endif
    }

    private var surface: some View {
        RemoteSurface(actions: remoteActions)
            // Back arrives here, through SwiftUI: the full-screen player's
            // own back handling closes it the moment the press starts,
            // before the view underneath hears it, unless this answers.
            .tvExitCommand { remoteActions.menu() }
            .accessibilityLabel(scrubTarget.map { String(localized: "Jump to \(PlayerClock.clock($0))") }
                                ?? (engine.isPlaying ? String(localized: "Pause") : String(localized: "Play")))
            .accessibilityValue(engine.item.displayTitle)
    }

    /// Something offered over the picture, in the corner above the controls:
    /// up takes it, and so does a tap.
    private func offer(_ words: String, touchIcon: String, spoken: String, take: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Image(systemName: isTouch ? touchIcon : "arrow.up.circle.fill")
                .font(.app(22, .bold))
            Text(words)
                .font(.app(22, .bold))
        }
        .padding(.horizontal, 26)
        .padding(.vertical, 14)
        .background {
            Capsule().fill(.black.opacity(0.7))
                .background(.ultraThinMaterial, in: Capsule())
                .overlay { Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 1) }
        }
        .padding(.leading, leadingMargin)
        .padding(.trailing, trailingMargin)
        // Above the controls when they're up: lower on a phone on its
        // side, where 300 points is most of the way up the screen.
        .padding(.bottom, controlsVisible ? (short ? 190 : 300) : max(60, bottomMargin))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .transition(.opacity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isTouch ? words : spoken)
        #if !os(tvOS)
        .onTapGesture(perform: take)
        #endif
    }

    /// A finger on the screen rather than a remote in the hand.
    private var isTouch: Bool {
        #if !os(tvOS)
        true
        #else
        false
        #endif
    }

    /// Paused, they stay up until put away; playing, they fade on their own.
    /// Below the fold of an iPhone Duo standing half-open, they cover none
    /// of the picture, and stay.
    private var controlsVisible: Bool {
        !showingInfo && (tabletop || mode != .picture || overlayShown || scrubTarget != nil)
    }

    // MARK: Remote

    private var remoteActions: RemoteSurface.Actions {
        RemoteSurface.Actions(
            select: {
                switch mode {
                case .menu(let menu):
                    let items = menuItems(menu)
                    guard items.indices.contains(menuIndex) else { return mode = .row }
                    // Taken before it's chosen: choosing may move the
                    // highlight, to a line of the list it opens.
                    let item = items[menuIndex]
                    item.choose()
                    // The sound is set by trying: the list stays up, to go on
                    // from what was just chosen once it's been heard. So does
                    // a line that opens another list, or waits on the server.
                    if menu != .audioSync, !item.staysOpen { mode = .row }
                case .row:
                    let menu = availableMenus[min(rowIndex, availableMenus.count - 1)]
                    if menu == .stats { toggleStats() } else { openMenu(menu) }
                case .picture:
                    if showingInfo { showingInfo = false }
                    else if scrubTarget != nil { commitScrub() }
                    else { playPause(); showOverlay() }
                }
            },
            playPause: { if scrubTarget != nil { commitScrub() } else { playPause(); showOverlay() } },
            menu: {
                switch mode {
                case .menu(.subtitleLanguage): menuIndex = 0; mode = .menu(.findSubtitles)
                case .menu(.findSubtitles):
                    // Onto the line it was opened from, the last.
                    menuIndex = max(menuItems(.subtitles).count - 1, 0)
                    mode = .menu(.subtitles)
                case .menu: mode = .row
                case .row: mode = .picture; showOverlay()
                case .picture:
                    // Back puts away whatever is showing, and only leaves
                    // the film from a bare picture.
                    if showingInfo { showingInfo = false }
                    else if scrubTarget != nil { cancelScrub() }
                    else if overlayShown { hideControls() }
                    else { onClose() }
                }
            },
            up: {
                switch mode {
                case .menu(let menu): menuIndex = max(menuIndex - 1, 0); _ = menu
                case .row: break
                case .picture:
                    if showingInfo {
                        showingInfo = false
                    } else if undoSkip != nil, scrubTarget == nil {
                        takeUndo()
                    } else if let skip = engine.activeSkip, scrubTarget == nil {
                        jump(to: skip.end)
                        showOverlay()
                    } else if offeredFix != nil, scrubTarget == nil {
                        takeOfferedFix()
                    } else {
                        // Up lands on subtitles, where the system bar kept them.
                        enterRow(at: availableMenus.firstIndex(of: .subtitles))
                    }
                }
            },
            down: {
                switch mode {
                case .menu(let menu): menuIndex = min(menuIndex + 1, menuItems(menu).count - 1)
                // Down from the row goes back to the picture, as from the
                // system bar's buttons.
                case .row: mode = .picture; showOverlay()
                case .picture:
                    // What's playing, the way the system player's swipe down
                    // shows it; down again puts it away.
                    if showingInfo {
                        showingInfo = false
                    } else {
                        if scrubTarget != nil { cancelScrub() }
                        showingInfo = true
                    }
                }
            },
            tap: { direction in
                switch mode {
                case .menu: break
                case .row: moveRow(by: direction)
                case .picture:
                    showingInfo = false
                    // Playing, a click skips; paused or scrubbing, it steps.
                    if engine.isPlaying, scrubTarget == nil {
                        moved()
                        skip(by: direction < 0 ? -10 : 30)
                    } else {
                        beginScrub()
                        moveMark(by: direction * 10)
                    }
                    showOverlay()
                }
            },
            hold: { direction, held, step in
                guard mode == .picture else { return }
                showingInfo = false
                // Thirty seconds of film a second to start, doubling every
                // second held, up to ten minutes a second.
                beginScrub()
                let speed = min(30 * pow(2, held), 600)
                moveMark(by: direction * speed * step)
            },
            swipe: { points in
                switch mode {
                case .menu: break
                case .row:
                    // A button's width of finger per button.
                    swipeCarry += points
                    if abs(swipeCarry) >= 90 {
                        moveRow(by: swipeCarry < 0 ? -1 : 1)
                        swipeCarry = 0
                    }
                case .picture:
                    showingInfo = false
                    // Finer on a short film, coarser on a long one: a full
                    // swipe across the touch surface is about a quarter of one.
                    beginScrub()
                    let perPoint = min(max(engine.duration / 8000, 0.1), 2)
                    moveMark(by: Double(points) * perPoint)
                }
            },
            touch: { _ in
                // A tap on the picture closes whatever is open, or else
                // shows or hides the controls.
                if mode != .picture { mode = .picture; showOverlay() }
                else if showingInfo { showingInfo = false }
                else if scrubTarget != nil { cancelScrub() }
                else if overlayShown { hideControls() }
                else { showOverlay() }
            },
            doubleTouch: { x in
                guard mode == .picture, scrubTarget == nil else { return }
                showingInfo = false
                moved()
                skip(by: x < 0.5 ? -10 : 10)
                showOverlay()
            })
    }

    private func enterRow(at index: Int? = nil) {
        if scrubTarget != nil { cancelScrub() }
        showingInfo = false
        if let index { rowIndex = index }
        rowIndex = min(max(rowIndex, 0), max(availableMenus.count - 1, 0))
        swipeCarry = 0
        mode = .row
    }

    private func moveRow(by step: Double) {
        rowIndex = min(max(rowIndex + (step < 0 ? -1 : 1), 0), max(availableMenus.count - 1, 0))
    }

    private func openMenu(_ menu: Menu) {
        // Audio Sync opens on its first line, which acts; the others open on
        // what's ticked.
        menuIndex = menu == .audioSync ? 0 : menuItems(menu).firstIndex(where: \.chosen) ?? 0
        // In a group, its members are only listed: onto the way out.
        if menu == .together, group.isInGroup { menuIndex = max(menuItems(menu).count - 1, 0) }
        mode = .menu(menu)
        if menu == .together, !group.isInGroup {
            Task { groupsListed = await group.groups() }
        }
    }

    // MARK: Controls

    /// A phone on its side: not a phone's width (a large one counts as wide
    /// there), but too little height for the margins a television or a tablet
    /// has, which left the timeline a third of the way up the picture.
    private var short: Bool {
        #if os(iOS)
        tabletop || (!narrow && verticalSize == .compact)
        #else
        false
        #endif
    }

    /// A list is open from the row.
    private var menuOpen: Bool {
        if case .menu = mode { return true }
        return false
    }

    #if os(iOS)
    /// The screen's safe area. The player fills the screen and ignores it, so
    /// the controls keep clear of the island, the corners and the home
    /// indicator themselves: the title sat under the island on a phone held
    /// upright.
    @State private var insets = UIEdgeInsets.zero
    /// How wide the screen is, for a list that would otherwise be as wide as
    /// its longest line: a subtitle's name ran off both edges of a phone.
    @State private var screenWidth = CGFloat.infinity

    private func readInsets() {
        let window = AppWindow.current
        let now = window?.safeAreaInsets ?? .zero
        if now != insets { insets = now }
        if let width = window?.bounds.width, width != screenWidth { screenWidth = width }
    }
    #elseif os(macOS)
    /// The film's window's width, as a list opens in it.
    private var screenWidth: CGFloat { AppWindow.size.width }
    #endif

    /// The controls' margins: a television's, a phone's, or a phone on its
    /// side's, and never inside the screen's safe area. Each side its own:
    /// a phone on its side has the same inset both ways, but an iPhone Duo
    /// folded has its camera strip down one side only, and the other side
    /// wasn't to lose as much.
    #if os(iOS)
    private var leadingMargin: CGFloat { sideMargin(inset: layoutDirection == .rightToLeft ? insets.right : insets.left) }
    private var trailingMargin: CGFloat { sideMargin(inset: layoutDirection == .rightToLeft ? insets.left : insets.right) }
    #else
    private var leadingMargin: CGFloat { sideMargin(inset: 0) }
    private var trailingMargin: CGFloat { sideMargin(inset: 0) }
    #endif

    private func sideMargin(inset: CGFloat) -> CGFloat {
        let base: CGFloat = narrow ? 20 : (short ? 56 : 80)
        return max(base, inset + 8)
    }

    private var topMargin: CGFloat {
        let base: CGFloat = narrow ? 16 : (short ? 18 : 50)
        #if os(iOS)
        return max(base, insets.top + 6)
        #else
        return base
        #endif
    }

    private var bottomMargin: CGFloat {
        let base: CGFloat = narrow ? 24 : (short ? 20 : 56)
        #if os(iOS)
        return max(base, insets.bottom + 10)
        #else
        return base
        #endif
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 0) {
            // On a phone on its side, the title and its buttons make way while
            // a list is open: with them there the list had no height left
            // and showed its heading alone.
            if !(short && menuOpen) {
            HStack(alignment: .top, spacing: 24) {
                #if os(iOS)
                touchButton("xmark", size: 22, label: String(localized: "Close")) { onClose() }
                #endif
                titleBlock
                #if os(iOS)
                Spacer(minLength: 0)
                // Into the small window, with the app back in use around it.
                // Not there for a film VLC is playing, which has no picture
                // the system can take.
                if pip.isPossible {
                    touchButton("pip.enter", size: 22, label: String(localized: "Picture in Picture", comment: "Player button: shrinks the film to the system's small floating window")) {
                        pip.start()
                    }
                }
                // To an Apple TV or AirPlay speaker.
                AirPlayButton()
                    .frame(width: 46, height: 46)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                #endif
            }
                .padding(.leading, leadingMargin)
                .padding(.trailing, trailingMargin)
                .padding(.top, topMargin)
                .padding(.bottom, short ? 40 : 90)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
            }
            #if os(iOS)
            // Below an iPhone Duo's fold the half is short: the play and skip
            // buttons go between the title and the timeline rather than over
            // the middle, where they lay on the row of buttons.
            if tabletop {
                Spacer(minLength: 8)
                if mode == .picture, scrubTarget == nil { transport.frame(maxWidth: .infinity) }
                Spacer(minLength: 8)
            } else {
                Spacer(minLength: 0)
            }
            #else
            Spacer(minLength: 0)
            #endif
            timeline
                .padding(.leading, leadingMargin)
                .padding(.trailing, trailingMargin)
                .padding(.top, tabletop ? 8 : narrow ? 40 : (short ? 24 : 80))
                .padding(.bottom, bottomMargin)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        #if !os(tvOS)
        .overlay { if !tabletop, mode == .picture, scrubTarget == nil { transport } }
        #endif
    }

    #if !os(tvOS)
    /// Back ten, play or pause, forward ten, in the middle of the picture.
    private var transport: some View {
        HStack(spacing: 56) {
            touchButton("gobackward.10", size: 30, label: String(localized: "Back 10 seconds")) {
                moved(); skip(by: -10); showOverlay()
            }
            touchButton(engine.isPlaying ? "pause.fill" : "play.fill", size: 44,
                        label: engine.isPlaying ? String(localized: "Pause") : String(localized: "Play")) {
                playPause(); showOverlay()
            }
            touchButton("goforward.10", size: 30, label: String(localized: "Forward 10 seconds")) {
                moved(); skip(by: 10); showOverlay()
            }
        }
        .opacity(engine.isLoading ? 0 : 1)
    }

    /// A round glass button for a finger.
    private func touchButton(_ icon: String, size: CGFloat, label: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: size * 2.1, height: size * 2.1)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.15), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    /// A finger along the timeline scrubs; letting go jumps there.
    private func timelineDrag(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard engine.duration > 0 else { return }
                beginScrub()
                let fraction = min(max(drag.location.x / max(width, 1), 0), 1)
                scrubTarget = min(fraction * engine.duration, max(engine.duration - 1, 0))
            }
            .onEnded { _ in commitScrub() }
    }
    #endif

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if engine.item.isEpisode {
                Text([engine.item.seriesName, engine.item.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                    .font(.app(20, .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(engine.item.displayTitle)
                    .font(.app(36, .bold))
                    .lineLimit(1)
                if let badge {
                    Text(badge)
                        .font(.app(13, .heavy))
                        .kerning(1.4)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .overlay(Capsule().stroke(.white.opacity(0.4), lineWidth: 1))
                        .foregroundStyle(.white.opacity(0.7))
                }
                if !engine.isPlaying && !engine.isLoading {
                    Image(systemName: "pause.fill")
                        .font(.app(26, .bold))
                }
            }
        }
    }

    private var timeline: some View {
        let shown = scrubTarget ?? engine.position
        return VStack(alignment: .leading, spacing: 18) {
            // On the right, where the system bar keeps its own.
            VStack(alignment: .trailing, spacing: 18) {
                if case .menu(let menu) = mode {
                    menuColumn(menu)
                        .transition(.opacity)
                }
                buttonRow
                    .scrollsSideways(narrow)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            // Nothing to do with it while the mark moves (Up ends a scrub):
            // it fades where it is, at the bottom, for the preview to ride
            // over its place, and comes back where it was.
            .opacity(scrubTarget == nil ? 1 : 0)
            .animation(.easeOut(duration: 0.2), value: scrubTarget == nil)
            Timeline(position: engine.position, target: scrubTarget, duration: engine.duration,
                     chapters: chapters, breaks: breaks)
                #if !os(tvOS)
                // A taller strip than the line itself, for a finger.
                .overlay {
                    GeometryReader { geometry in
                        Color.clear
                            .contentShape(Rectangle())
                            .padding(.vertical, -18)
                            .gesture(timelineDrag(width: geometry.size.width))
                    }
                }
                #endif
                // Above the mark, taking no room: what's beneath doesn't move.
                // Hung from a line of no height along the timeline's top.
                .overlay(alignment: .top) {
                    if let target = scrubTarget {
                        Color.clear
                            .frame(height: 0)
                            .overlay(alignment: .bottom) {
                                ScrubPreview(trickplay: trickplay, target: target, duration: engine.duration,
                                             caption: previewCaption(at: target))
                                    .padding(.bottom, 18)
                            }
                            .allowsHitTesting(false)
                    }
                }
            HStack(spacing: 14) {
                Text(PlayerClock.clock(shown))
                    .foregroundStyle(.white)
                if let target = scrubTarget {
                    Text(PlayerClock.delta(target - engine.position))
                        .foregroundStyle(Theme.accent)
                }
                Spacer()
                if scrubTarget != nil, !isTouch {
                    Text("Click to jump · Back to cancel")
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Text(endsAt(from: shown))
                    .foregroundStyle(.white.opacity(0.8))
                Text("-" + PlayerClock.clock(max(engine.duration - shown, 0)))
            }
            .font(.app(20, .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .monospacedDigit()
            .lineLimit(1)
        }
    }

    // MARK: Info

    /// What's playing, risen from the bottom of the screen: an episode's still or the
    /// film's backdrop, the title, a line of facts and the plot.
    private var infoCard: some View {
        let item = engine.item
        let still = item.isEpisode
            ? app?.client?.imageURL(for: item, type: "Primary", maxWidth: 800)
            : app?.client?.imageURL(for: item, type: "Backdrop", maxWidth: 800)
                ?? app?.client?.imageURL(for: item, type: "Primary", maxWidth: 800)
        return HStack(alignment: .top, spacing: 36) {
            RemoteImage(url: still)
                .frame(width: CGFloat(400).scaled, height: CGFloat(225).scaled)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 10) {
                if item.isEpisode {
                    Text([item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · ").uppercased())
                        .font(.app(15, .heavy))
                        .kerning(1.4)
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
                Text(item.displayTitle)
                    .font(.app(34, .bold))
                    .lineLimit(2)
                HStack(spacing: 12) {
                    if let aired = Recorded.aired(item) { Text(aired) } else if let year = item.productionYear { Text(verbatim: "\(year)") }
                    if let ticks = item.runTimeTicks {
                        Text(Duration.seconds(Double(ticks) / 10_000_000)
                            .formatted(.units(allowed: [.hours, .minutes], width: .narrow)))
                    }
                    if let rating = item.officialRating {
                        Text(rating)
                            .padding(.horizontal, 7)
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(.white.opacity(0.5), lineWidth: 1.5))
                    }
                    Text(endsAt(from: engine.position))
                }
                .font(.app(19, .semibold))
                .foregroundStyle(.white.opacity(0.75))
                if let overview = item.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.app(21))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .risenCard()
    }

    // MARK: The row of buttons

    private var availableMenus: [Menu] {
        var menus: [Menu] = []
        // There with nothing to list, too, when more can be looked for.
        if engine.trackList.subtitles.count > 1 || findsSubtitles { menus.append(.subtitles) }
        if engine.trackList.audio.count > 1 { menus.append(.audio) }
        if engine.audioDelay != nil { menus.append(.audioSync) }
        if engine.soundModes { menus.append(.sound) }
        if engine.subtitleDelay != nil { menus.append(.timing) }
        // Everyone in a group plays at the one speed.
        if together == nil { menus.append(.speed) }
        if chapters.count > 1 { menus.append(.chapters) }
        menus.append(.sleep)
        if watchesTogether { menus.append(.together) }
        if engine.playbackContext != nil { menus.append(.stats) }
        return menus
    }

    /// Each button says what it's set to, so the row reads as a summary even
    /// before it's used. Shown whenever the controls are; lit once the viewer
    /// moves onto it.
    /// The row at its fullest that fits the screen: track names cut shorter
    /// as need be. Wider than the screen, it pushed the whole player aside
    /// (a film whose default subtitle was "原碟官译简中 - Chinese - Default"
    /// lost its title and its time off either edge).
    private var buttonRow: some View {
        ViewThatFits(in: .horizontal) {
            buttonRow(limit: 26)
            buttonRow(limit: 14)
            buttonRow(limit: 7)
            #if !os(tvOS)
            // Wider than the screen even so (an iPad held upright has more
            // buttons than width): it scrolls sideways, rather than pushing
            // Close and the time off either edge.
            ScrollView(.horizontal, showsIndicators: false) { buttonRow(limit: 14) }
            #endif
        }
    }

    private func buttonRow(limit: Int) -> some View {
        HStack(spacing: 14) {
            ForEach(Array(availableMenus.enumerated()), id: \.element) { index, menu in
                RowPill(icon: icon(for: menu), text: label(for: menu), limit: limit,
                        lit: mode != .picture && index == rowIndex)
                    .accessibilityLabel(title(for: menu))
                    #if !os(tvOS)
                    .contentShape(Capsule())
                    .onTapGesture {
                        // A second tap on the open one closes it.
                        if menu == .stats { toggleStats() }
                        else if mode == .menu(menu) { mode = .picture } else { rowIndex = index; openMenu(menu) }
                        showOverlay()
                    }
                    #endif
            }
        }
    }

    /// Whether subtitles can be looked for on the internet for this film:
    /// the server lets this account, and the server is what's playing it.
    private var findsSubtitles: Bool {
        engine.takesFoundSubtitles && app?.findsSubtitles == true && app?.client != nil
    }

    private func icon(for menu: Menu) -> String {
        switch menu {
        case .subtitles, .findSubtitles, .subtitleLanguage: return "captions.bubble"
        case .audio: return "speaker.wave.2"
        case .audioSync: return "waveform"
        case .sound: return clarity.dialogueBoost ? "waveform.circle.fill" : "waveform.circle"
        case .timing: return "timer"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .chapters: return "list.bullet"
        case .sleep: return sleep.isSet ? "moon.zzz.fill" : "moon.zzz"
        case .together: return group.isInGroup ? "person.2.fill" : "person.2"
        case .stats: return showingStats ? "chart.bar.fill" : "chart.bar"
        }
    }

    private func title(for menu: Menu) -> String {
        switch menu {
        case .subtitles: return String(localized: "Subtitles")
        case .audio: return String(localized: "Audio", comment: "Heading over the list of audio tracks")
        case .audioSync: return String(localized: "Audio Sync", comment: "Menu in the player that moves the sound earlier or later against the picture")
        case .sound: return String(localized: "Sound", comment: "Player menu that holds Dialogue Boost")
        case .timing: return String(localized: "Timing", comment: "Menu that shifts subtitles earlier or later")
        case .speed: return String(localized: "Speed", comment: "Heading over the list of playback speeds")
        case .chapters: return String(localized: "Chapters")
        case .sleep: return SleepTimer.title
        case .together: return SyncPlay.title
        case .stats: return String(localized: "Stats", comment: "Button in the player's row that shows or hides a panel of technical facts about the playback")
        // The line that opens it, less its dots.
        case .findSubtitles: return Self.findSubtitlesLine.trimmingCharacters(in: CharacterSet(charactersIn: "… ."))
        case .subtitleLanguage: return String(localized: "Language", comment: "Preferred subtitle language setting")
        }
    }

    private static var findSubtitlesLine: String {
        String(localized: "Search for Subtitles…", comment: "Last line of the player's Subtitles menu: looks for subtitles for this film on the internet")
    }

    private func label(for menu: Menu) -> String {
        let tracks = engine.trackList
        switch menu {
        case .subtitles, .findSubtitles, .subtitleLanguage:
            return tracks.subtitles.first { $0.id == tracks.currentSubtitle }?.name
                ?? String(localized: "Off", comment: "Subtitles turned off")
        case .audio:
            return tracks.audio.first { $0.id == tracks.currentAudio }?.name ?? title(for: menu)
        case .audioSync:
            // Its own name while nothing is moved: "In Sync" beside the
            // subtitles' "On Time" would say the same thing twice.
            let delay = engine.audioDelay ?? 0
            return delay == 0 ? title(for: menu) : AudioSync.label(delay)
        case .sound:
            return clarity.dialogueBoost ? AudioClarityText.dialogue : title(for: menu)
        case .timing:
            return SubtitleTiming.label(engine.subtitleDelay ?? 0)
        case .speed:
            return PlaybackSpeed.label(engine.rate)
        case .sleep:
            return sleep.isSet ? sleep.summary() : title(for: menu)
        case .together:
            return group.group.map(SyncPlay.name(of:)) ?? title(for: menu)
        case .chapters, .stats:
            return title(for: menu)
        }
    }

    /// One line of a menu: what it says, what's ticked, and what choosing does.
    struct MenuItem {
        let title: String
        /// A second, smaller line under the first.
        var detail: String? = nil
        var trailing: String? = nil
        let chosen: Bool
        /// Choosing it leaves a menu up: this one, or the one it opens.
        var staysOpen = false
        let choose: () -> Void
    }

    private func menuItems(_ menu: Menu) -> [MenuItem] {
        let tracks = engine.trackList
        switch menu {
        case .subtitles:
            let listed = tracks.subtitles.map { track in
                MenuItem(title: track.name, chosen: track.id == tracks.currentSubtitle) { chooseSubtitle(track.id) }
            }
            guard findsSubtitles else { return listed }
            return listed + [MenuItem(title: Self.findSubtitlesLine, chosen: false, staysOpen: true) { openSubtitleSearch() }]
        case .stats:
            return []
        case .findSubtitles:
            return findingItems
        case .subtitleLanguage:
            let current = findingLanguage
            return SubtitleSearch.languages.map { language in
                MenuItem(title: language.name, chosen: language.code == current.code, staysOpen: true) {
                    finding.language = language
                    searchForSubtitles()
                    menuIndex = 1
                    mode = .menu(.findSubtitles)
                }
            }
        case .audio:
            return tracks.audio.map { track in
                MenuItem(title: track.name, chosen: track.id == tracks.currentAudio) { chooseAudio(track.id) }
            }
        case .audioSync:
            // A nudge at a time, each line saying where it would leave the
            // sound: the list stays up, so the same line is pressed again
            // until it looks right.
            let current = engine.audioDelay ?? 0
            let later = AudioSync.nudged(current, by: 1), earlier = AudioSync.nudged(current, by: -1)
            return detectionItems + [
                MenuItem(title: String(localized: "Later", comment: "In the player's Audio Sync menu: moves the sound a little later against the picture"),
                         trailing: later == current ? nil : AudioSync.label(later), chosen: false) { engine.setAudioDelay(later) },
                MenuItem(title: String(localized: "Earlier", comment: "In the player's Audio Sync menu: moves the sound a little earlier against the picture"),
                         trailing: earlier == current ? nil : AudioSync.label(earlier), chosen: false) { engine.setAudioDelay(earlier) },
                MenuItem(title: AudioSync.label(0), chosen: current == 0) { engine.setAudioDelay(0) },
            ]
        case .timing:
            let current = engine.subtitleDelay ?? 0
            return SubtitleTiming.steps.map { step in
                MenuItem(title: SubtitleTiming.label(step), chosen: step == current) { engine.setSubtitleDelay(step) }
            }
        case .sound:
            return [MenuItem(title: AudioClarityText.dialogue, detail: AudioClarityText.dialogueDetail,
                             chosen: clarity.dialogueBoost, staysOpen: true) { clarity.dialogueBoost.toggle() }]
        case .speed:
            return PlaybackSpeed.rates.map { rate in
                MenuItem(title: PlaybackSpeed.label(rate), chosen: rate == engine.rate) { engine.setRate(rate) }
            }
        case .sleep:
            return [MenuItem(title: String(localized: "Off", comment: "Subtitles turned off"), chosen: !sleep.isSet) { sleep.cancel() }]
                + SleepTimer.lengths.map { minutes in
                    MenuItem(title: SleepTimer.length(minutes), chosen: false) { sleep.set(minutes: minutes) }
                }
                + [MenuItem(title: SleepTimer.whenThisEnds, chosen: sleep.atEnd) { sleep.setAtEnd() }]
        case .together:
            return togetherItems
        case .chapters:
            let current = chapters.lastIndex { $0.startSeconds <= engine.position }
            return chapters.enumerated().map { index, chapter in
                MenuItem(title: chapter.name ?? String(localized: "Chapter \(index + 1)"),
                         trailing: PlayerClock.clock(chapter.startSeconds),
                         chosen: index == current) {
                    moved()
                    jump(to: chapter.startSeconds)
                }
            }
        }
    }

    /// The line at the head of Audio Sync that works the sound's place out
    /// from the subtitles: what it offers changes with where it has got to.
    private var detectionItems: [MenuItem] {
        guard let detection = engine.audioSyncDetection else { return [] }
        switch detection {
        case .idle:
            return [MenuItem(title: String(localized: "Detect from Subtitles", comment: "In the player's Audio Sync menu: works out how far the sound is out by comparing speech with the subtitles"),
                             chosen: false) { engine.detectAudioSync() }]
        case .listening(let seconds):
            // Chosen again, it stops.
            return [MenuItem(title: String(localized: "Listening…", comment: "In the player's Audio Sync menu: the detection is under way"),
                             trailing: PlayerClock.clock(seconds), chosen: false) { engine.detectAudioSync() }]
        case .found(let fix):
            return [MenuItem(title: String(localized: "Use \(AudioSync.label(fix))", comment: "In the player's Audio Sync menu: applies what the detection found. The placeholder is an offset, like 0.7 s Later"),
                             chosen: false) { engine.setAudioDelay(fix) }]
        case .inSync:
            return [MenuItem(title: String(localized: "Sounds In Sync", comment: "In the player's Audio Sync menu: the detection found nothing to correct"),
                             chosen: false) { engine.detectAudioSync() }]
        case .unsure:
            return [MenuItem(title: String(localized: "Couldn't Tell", comment: "In the player's Audio Sync menu: the detection couldn't work the offset out"),
                             chosen: false) { engine.detectAudioSync() }]
        }
    }

    // MARK: Watching together

    /// Whether the account may watch together here: a film, on a server
    /// that lets it.
    private var watchesTogether: Bool {
        togetherHooks != nil && (group.access != .none || group.isInGroup)
    }

    /// In a group: who's in it, and the way out. Otherwise: a new group, and
    /// the groups on the server to join.
    private var togetherItems: [MenuItem] {
        var items: [MenuItem] = []
        if let problem = group.problem {
            items.append(MenuItem(title: problem, chosen: false, staysOpen: true) { group.problem = nil })
        }
        if let current = group.group {
            items += (current.participants ?? []).map { name in
                MenuItem(title: name, chosen: false, staysOpen: true) {}
            }
            items.append(MenuItem(title: SyncPlay.leaveTitle, chosen: false) {
                Task { await group.leave() }
            })
            return items
        }
        if group.access == .create {
            items.append(MenuItem(title: SyncPlay.startTitle, chosen: false) {
                let name = SyncPlay.newGroupName(for: app?.userName)
                Task { await group.create(named: name) }
            })
        }
        items += groupsListed.map { listed in
            MenuItem(title: SyncPlay.joinTitle(listed), detail: SyncPlay.members(of: listed), chosen: false) {
                Task { await group.join(listed.groupId) }
            }
        }
        if items.isEmpty {
            items.append(MenuItem(title: SyncPlay.noGroupsTitle, chosen: false, staysOpen: true) {})
        }
        return items
    }

    /// Joined or left: playing as the group says, or alone again.
    private func followGroup(_ groupId: String?) {
        together?.detach()
        together = nil
        guard groupId != nil, let hooks = togetherHooks else { return }
        let engine = engine
        let driver = SyncPlayDriver(sync: group, controls: SyncPlayDriver.Controls(
            item: engine.item, onward: hooks.onward,
            position: { engine.position },
            isPlaying: { engine.isPlaying },
            isLoading: { engine.isLoading },
            play: { if !engine.isPlaying { engine.togglePause() } },
            pause: { if engine.isPlaying { engine.togglePause() } },
            seek: { engine.seek(toFilmSeconds: $0) },
            switchTo: hooks.switchTo,
            stop: hooks.stop))
        together = driver
        driver.start()
    }

    /// Play or pause; asked of the group while watching together, which has
    /// everyone do it.
    private func playPause() {
        if let together { together.togglePause() } else { engine.togglePause() }
    }

    /// To a moment of the film; for everyone, while watching together.
    private func jump(to seconds: Double) {
        if let together { together.seek(to: seconds) } else { engine.seek(toFilmSeconds: seconds) }
    }

    private func skip(by seconds: Int32) {
        if let together { together.seek(to: engine.position + Double(seconds)) } else { engine.skip(seconds) }
    }

    // MARK: Played from another device

    /// What a phone's commands do here: as the remote's own presses would,
    /// and the tracks by the server's numbering of the film's streams.
    private var remoteControls: RemoteControl.Player {
        let engine = engine
        return RemoteControl.Player(
            itemId: engine.item.id,
            play: { if !engine.isPlaying { playPause() } },
            pause: { if engine.isPlaying { playPause() } },
            togglePause: { playPause() },
            seek: { jump(to: $0) },
            skip: { jump(to: max(engine.position + $0, 0)) },
            stop: { onClose() },
            audio: { index in
                if let id = engine.playbackContext?.trackId(forServerIndex: index, in: engine.trackList.audio, kind: "Audio") {
                    chooseAudio(id)
                }
            },
            subtitle: { index in
                if index < 0 { return chooseSubtitle(TrackList.subtitlesOff) }
                if let id = engine.playbackContext?.trackId(forServerIndex: index, in: engine.trackList.subtitles, kind: "Subtitle") {
                    chooseSubtitle(id)
                }
            })
    }

    // MARK: Tracks chosen

    /// Audio chosen by the viewer. With subtitles "Only when needed", they
    /// follow it: on for a language not the viewer's, off again (or to the
    /// forced ones) for their own. A show remembers both for its other episodes.
    private func chooseAudio(_ id: String) {
        let tracks = engine.trackList
        if let subtitle = SubtitleRule.subtitle(afterChoosing: id, tracks: tracks, context: engine.playbackContext,
                                                preferences: app?.preferences),
           subtitle != tracks.currentSubtitle {
            engine.selectTracks(audio: id, subtitle: subtitle)
            remember(audio: id, subtitle: subtitle)
        } else {
            engine.selectAudio(id)
            remember(audio: id, subtitle: tracks.currentSubtitle)
        }
    }

    private func chooseSubtitle(_ id: String) {
        engine.selectSubtitle(id)
        remember(audio: engine.trackList.currentAudio, subtitle: id)
    }

    /// What's on now, in a show: kept for its next episode (see `TrackMemory`).
    private func remember(audio: String?, subtitle: String?) {
        guard PlaybackPreferences.remembersTracks, let show = engine.item.seriesId, let context = engine.playbackContext else { return }
        let tracks = engine.trackList
        func stream(_ index: Int?, _ kind: String) -> MediaStream? {
            index.flatMap { wanted in context.mediaStreams.first { $0.index == wanted && $0.type == kind } }
        }
        TrackMemory.remember(show: show,
                             audio: stream(context.serverIndex(forTrackId: audio, in: tracks.audio, kind: "Audio"), "Audio"),
                             subtitle: stream(context.serverIndex(forTrackId: subtitle, in: tracks.subtitles, kind: "Subtitle"), "Subtitle"),
                             subtitleOff: subtitle == TrackList.subtitlesOff)
    }

    // MARK: Stats

    private func toggleStats() {
        showingStats.toggle()
        PlaybackStats.shown = showingStats
    }

    /// Reads the panel's lines afresh every second while it's up. What the
    /// server says of a conversion is asked for every so often rather than
    /// once: it only knows a few seconds after the stream has started.
    private func followStats() async {
        guard showingStats else { return statLines = [] }
        var transcoding: TranscodingInfo?
        var asked = Date.distantPast
        while !Task.isCancelled {
            if let context = engine.playbackContext {
                if context.engine == .avPlayer, !context.isDirect, Date().timeIntervalSince(asked) > 8,
                   let client = app?.client {
                    asked = Date()
                    transcoding = await client.transcoding(of: context.item.id) ?? transcoding
                }
                let tracks = engine.trackList
                let subtitle = tracks.currentSubtitle == TrackList.subtitlesOff ? nil
                    : tracks.subtitles.first { $0.id == tracks.currentSubtitle }?.name
                let lines = PlaybackStats.lines(
                    context: context, live: engine.liveStats(), transcoding: transcoding,
                    audioTrack: tracks.audio.first { $0.id == tracks.currentAudio }?.name,
                    subtitleTrack: subtitle,
                    server: [app?.serverName, app?.client?.baseURL.host].compactMap { $0 }.joined(separator: " · "),
                    display: DisplayCriteria.summary)
                if lines != statLines { statLines = lines }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Subtitles from the internet

    private var findingLanguage: SubtitleLanguage {
        finding.language ?? SubtitleSearch.openingLanguage(app?.preferences)
    }

    /// The language, then whatever the search has to say for itself: that
    /// it's still asking, that it went wrong, that nothing came back, or what
    /// did, each a line to choose.
    private var findingItems: [MenuItem] {
        let language = findingLanguage
        var items = [MenuItem(title: title(for: .subtitleLanguage), trailing: language.name, chosen: false, staysOpen: true) {
            menuIndex = SubtitleSearch.languages.firstIndex { $0.code == language.code } ?? 0
            mode = .menu(.subtitleLanguage)
        }]
        if let refused = finding.refused {
            items.append(MenuItem(title: refused, chosen: false, staysOpen: true) {})
        }
        guard let results = finding.results else {
            if finding.failed {
                return items + [MenuItem(title: String(localized: "Search failed. Try again", comment: "In the player's subtitle search: the server couldn't be asked; choosing the line asks again"),
                                         chosen: false, staysOpen: true) { searchForSubtitles() }]
            }
            return items + [MenuItem(title: String(localized: "Searching…", comment: "In the player's subtitle search: waiting for the server's answer"),
                                     chosen: false, staysOpen: true) {}]
        }
        if results.isEmpty {
            return items + [MenuItem(title: String(localized: "Nothing found in \(language.name)", comment: "In the player's subtitle search: no subtitles came back. The placeholder is a language's name"),
                                     chosen: false, staysOpen: true) { searchForSubtitles() }]
        }
        return items + results.map { result in
            let fetching = finding.fetching == result.id
            return MenuItem(title: result.listedName, detail: result.listedDetail,
                            trailing: fetching ? String(localized: "Fetching…", comment: "In the player's subtitle search: the server is downloading the chosen subtitle")
                                               : result.listedDownloads,
                            chosen: false, staysOpen: true) { fetch(result) }
        }
    }

    private func openSubtitleSearch() {
        // On the line under Language: where the first of what's found will be.
        menuIndex = 1
        mode = .menu(.findSubtitles)
        if finding.results == nil { searchForSubtitles() }
    }

    private func searchForSubtitles() {
        guard let client = app?.client else { return }
        let language = findingLanguage
        let target = SubtitleSearch.target(for: engine.item, mediaSourceId: engine.mediaSourceId, on: client)
        finding.task?.cancel()
        finding.results = nil
        finding.failed = false
        finding.refused = nil
        finding.task = Task {
            do {
                let found = try await client.remoteSubtitles(for: target, language: language.code)
                guard !Task.isCancelled else { return }
                finding.results = SubtitleSearch.ordered(found)
            } catch {
                guard !Task.isCancelled else { return }
                finding.failed = true
            }
            // The highlight was on the line that said it was searching.
            if case .menu(.findSubtitles) = mode { menuIndex = min(menuIndex, max(findingItems.count - 1, 0)) }
        }
    }

    /// Has the server fetch the one chosen, and puts it on once it's there.
    /// One at a time: each costs the server's account one of its day's.
    private func fetch(_ result: RemoteSubtitle) {
        guard finding.fetching == nil, let client = app?.client else { return }
        let language = findingLanguage, item = engine.item, source = engine.mediaSourceId
        finding.fetching = result.id
        finding.refused = nil
        finding.fetch = Task {
            do {
                let found = try await SubtitleSearch.fetch(result, in: language, for: item, mediaSourceId: source, client: client)
                guard !Task.isCancelled else { return }
                engine.show(found)
                finding.fetching = nil
                // Back to the picture, to read it.
                if case .menu(.findSubtitles) = mode { mode = .picture }
                showOverlay()
            } catch {
                guard !Task.isCancelled else { return }
                finding.fetching = nil
                finding.refused = error.localizedDescription
                if case .menu(.findSubtitles) = mode { menuIndex = 1 }
            }
        }
    }

    private func accent(for menu: Menu) -> (Color, Color) {
        switch menu {
        case .audio, .audioSync, .sound: return Theme.palette[0]
        case .subtitles, .timing, .findSubtitles, .subtitleLanguage: return Theme.palette[2]
        case .speed, .chapters, .stats: return Theme.palette[3]
        case .sleep: return Theme.palette[1]
        case .together: return Theme.palette[0]
        }
    }

    /// The list a button opens, above the row on the right, with the line the
    /// presses have reached lit. A long one (a film's chapters) shows the
    /// stretch around that line, and moves along as the presses do.
    private func menuColumn(_ menu: Menu) -> some View {
        #if !os(tvOS)
        // Every line, scrolling, each one a tap.
        let items = menuItems(menu)
        return PlayerPanelColumn(title: title(for: menu), accent: accent(for: menu)) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        PlayerPanelRow(title: item.title, detail: item.detail, trailing: item.trailing, chosen: item.chosen)
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                item.choose()
                                if menu != .audioSync, !item.staysOpen { mode = .picture }
                                showOverlay()
                            }
                    }
                }
            }
            // Never squeezed to nothing by what's above and below it: a
            // few lines at least, scrolling for the rest.
            .frame(minHeight: min(CGFloat(items.count) * 48, 144), maxHeight: 420)
        }
        .frame(maxWidth: min(CGFloat(760).scaled, screenWidth - leadingMargin - trailingMargin), alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        #else
        let items = menuItems(menu)
        // Fewer of the taller lines a search's are.
        let visible = menu == .findSubtitles ? 6 : 9
        let first = min(max(menuIndex - visible / 2, 0), max(items.count - visible, 0))
        let shown = Array(items.enumerated()).dropFirst(first).prefix(visible)
        return PlayerPanelColumn(title: title(for: menu), accent: accent(for: menu)) {
            ForEach(Array(shown), id: \.offset) { index, item in
                PlayerPanelRow(title: item.title, detail: item.detail, trailing: item.trailing, chosen: item.chosen)
                    .foregroundStyle(index == menuIndex ? Color.black : Color.white)
                    .background {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(index == menuIndex ? Color.white : Color.clear)
                    }
            }
        }
        .frame(maxWidth: CGFloat(760).scaled, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        #endif
    }

    // MARK: Words

    /// "Chapter 4 · 1:08:05", or just the time for a film with no chapters.
    private func previewCaption(at seconds: Double) -> String {
        let time = PlayerClock.clock(seconds)
        guard chapters.count > 1, let index = chapters.lastIndex(where: { $0.startSeconds <= seconds }) else { return time }
        let name = chapters[index].name ?? String(localized: "Chapter \(index + 1)")
        return "\(name) · \(time)"
    }

    /// When the film will finish from here at the speed it's playing.
    private func endsAt(from seconds: Double) -> String {
        let left = max(engine.duration - seconds, 0) / Double(max(engine.rate, 0.1))
        let time = Date().addingTimeInterval(left).formatted(date: .omitted, time: .shortened)
        return String(localized: "Ends at \(time)", comment: "When the film will finish; the placeholder is a time of day, like 9:47 PM")
    }

    // MARK: Scrubbing

    /// A scrub holds the picture still where it was, the way the system
    /// player's does, and remembers whether to play on if it's cancelled.
    private func beginScrub() {
        guard scrubTarget == nil else { return }
        // Watching together, the film plays on for everyone while the mark
        // is moved, and the group goes there together.
        resumeAfterScrub = engine.isPlaying && together == nil
        if resumeAfterScrub { engine.togglePause() }
        scrubTarget = engine.position
        showOverlay()
    }

    private func moveMark(by seconds: Double) {
        let from = scrubTarget ?? engine.position
        // Stop short of the very end, which would end the film rather than
        // show its last moments.
        let last = engine.duration > 1 ? engine.duration - 1 : max(from + seconds, 0)
        scrubTarget = min(max(from + seconds, 0), last)
    }

    private func commitScrub() {
        guard let target = scrubTarget else { return }
        moved()
        jump(to: target)   // plays on from there
        scrubTarget = nil
        showOverlay()
    }

    /// Takes the skip without waiting to be asked, when Settings says to: an
    /// intro or credits the film has played its way into, or opened inside.
    /// Not one the viewer has just moved into, nor one skipped already, nor
    /// credits that are only a guess: those are offered.
    private func skipUnasked(_ skip: SkipSegment?) async {
        // Not for a group, where every member's player would ask at once:
        // offered, and whoever takes it moves everyone.
        guard together == nil else { return }
        guard let skip, !skip.guessed, !skips.skipped.contains(skip.id) else { return }
        let wanted = switch skip.kind {
        case .intro: PlaybackPreferences.autoSkipIntros
        case .outro: PlaybackPreferences.autoSkipCredits
        case .commercial: PlaybackPreferences.autoSkipCommercials
        case .recap, .preview: PlaybackPreferences.autoSkipRecaps
        }
        guard wanted else { return }
        // Judged as it's entered: a move made since then is within it.
        let moved = skips.movedAt
        guard Date().timeIntervalSince(moved) > 5 else { return }
        // The players don't all say where they are and that they're playing
        // in the same order: a few seconds either way is still the opening.
        let opening = skips.openedAt.map { Date().timeIntervalSince($0) < 3 } ?? true
        if engine.isLoading || !engine.isPlaying {
            // A player still opening says it's at the start, where an intro
            // often is, before it goes to where the film was left; skipping
            // on its word sent a resumed episode back to the end of its
            // intro. So nothing is skipped until the film is seen playing its
            // way through the segment.
            var seen: Double?
            while true {
                try? await Task.sleep(for: .milliseconds(200))
                guard !Task.isCancelled, engine.activeSkip == skip else { return }
                let now = engine.position
                guard !engine.isLoading, engine.isPlaying, skip.contains(now) else { seen = nil; continue }
                if let seen, now > seen, now - seen < 3 { break }
                seen = now
            }
        }
        guard !Task.isCancelled, engine.activeSkip == skip, scrubTarget == nil,
              skips.movedAt == moved, !skips.skipped.contains(skip.id) else { return }
        // Part-way into it with the film already going: something moved it
        // there that these controls didn't (the lock screen's timeline, a
        // remote's skip buttons), and that was someone's doing too.
        guard opening || engine.position - skip.start < 4 else { return }
        skips.skipped.insert(skip.id)
        if skip.kind == .outro { creditsSkipped?() }
        let from = engine.position
        engine.seek(toFilmSeconds: skip.end)
        showOverlay()
        if skip.kind == .commercial { offerUndo(to: from) }
    }

    /// The viewer moved through the film themselves: wherever that lands is
    /// where they went, and a skip before it is no longer theirs to undo.
    private func moved() {
        skips.movedAt = Date()
        undoSkip = nil
    }

    /// Offers the way back for a while after a skip nobody asked for.
    private func offerUndo(to seconds: Double) {
        undoSkip = seconds
        Task {
            try? await Task.sleep(for: .seconds(12))
            if undoSkip == seconds { undoSkip = nil }
        }
    }

    /// Back to where the skip was made, to play on through what it took for
    /// commercials: skipped the once already, so now it is only offered.
    private func takeUndo() {
        guard let from = undoSkip else { return }
        moved()
        jump(to: from)
        showOverlay()
    }

    private func cancelScrub() {
        scrubTarget = nil
        if resumeAfterScrub, !engine.isPlaying { engine.togglePause() }
        showOverlay()
    }

    /// Shows the controls, then fades them out after a few seconds of no
    /// input, unless the film is paused, when they wait to be put away.
    private func showOverlay() {
        overlayShown = true
        hideOverlay?.cancel()
        hideOverlay = Task {
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled, engine.isPlaying, mode == .picture { overlayShown = false }
        }
    }

    private func hideControls() {
        hideOverlay?.cancel()
        overlayShown = false
    }

    private func takeOfferedFix() {
        guard let fix = offeredFix else { return }
        offeredFix = nil
        engine.setAudioDelay(fix)
        showOverlay()
    }
}

/// A button in the row: an icon and what it's set to.
extension View {
    /// The look of the card that rises from the bottom of the picture to
    /// say what's playing: a film's, and a television channel's.
    func risenCard() -> some View {
        self
            .padding(36)
            .frame(maxWidth: CGFloat(1500).scaled)
            .background {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.black.opacity(0.6))
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                    }
            }
            .padding(.horizontal, 80)
            .padding(.bottom, 60)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .accessibilityElement(children: .combine)
    }
}

private struct RowButtonLabel: View {
    let icon: String
    let text: String
    /// The longest a name is shown, where the row has to be kept narrow.
    var limit = 26

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.app(20, .semibold))
            Text(Self.short(text, limit: limit))
                .font(.app(20, .bold))
                .lineLimit(1)
        }
        .fixedSize()
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
    }
}

extension RowButtonLabel {
    /// Track names can run long ("English - Dolby TrueHD + Dolby Atmos - 7.1");
    /// the button keeps to the start of one, and the menu has the rest.
    static func short(_ text: String, limit: Int = 26) -> String {
        text.count > limit ? String(text.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…" : text
    }
}

/// A button in the row: white when lit, a quiet glass pill otherwise.
private struct RowPill: View {
    let icon: String
    let text: String
    var limit = 26
    let lit: Bool

    var body: some View {
        RowButtonLabel(icon: icon, text: text, limit: limit)
            .foregroundStyle(lit ? Color.black : Color.white)
            .background { Capsule().fill(lit ? Color.white : Color.white.opacity(0.16)) }
            .scaleEffect(lit ? 1.06 : 1)
            .shadow(color: .black.opacity(lit ? 0.45 : 0), radius: 14, y: 6)
            .animation(.easeOut(duration: 0.12), value: lit)
    }
}

/// The picture, as far as the remote is concerned: a focusable view that
/// hears every press and every swipe on the touch surface, which SwiftUI
/// can't — a held arrow arrives there as one press, and a swipe not at all.
struct RemoteSurface: UIViewRepresentable {
    struct Actions {
        var select: () -> Void = {}
        var playPause: () -> Void = {}
        var menu: () -> Void = {}
        var up: () -> Void = {}
        var down: () -> Void = {}
        /// A quick click of left (-1) or right (+1).
        var tap: (Double) -> Void = { _ in }
        /// Left or right held down: the direction, seconds held so far
        /// beyond the first moment, and seconds since the last call.
        var hold: (Double, Double, Double) -> Void = { _, _, _ in }
        /// A finger moving sideways on the touch surface, in points.
        var swipe: (CGFloat) -> Void = { _ in }
        /// A finger on the screen itself (iPad): a tap, and a double tap, each
        /// with how far across the screen it landed, 0 to 1.
        var touch: (Double) -> Void = { _ in }
        var doubleTouch: (Double) -> Void = { _ in }
    }

    let actions: Actions

    func makeUIView(context: Context) -> RemoteSurfaceView {
        let view = RemoteSurfaceView()
        view.actions = actions
        return view
    }

    func updateUIView(_ view: RemoteSurfaceView, context: Context) {
        view.actions = actions
    }

    static func dismantleUIView(_ view: RemoteSurfaceView, coordinator: ()) {
        view.stopHolding()
    }
}

// The Mac's is in macOS/MacRemoteSurface.swift: keys and the trackpad, not presses.
#if !os(macOS)
final class RemoteSurfaceView: UIView {
    var actions = RemoteSurface.Actions()

    private var holdTimer: Timer?
    private var holdStart: Date?
    private var lastTick: Date?
    private var holdDirection: Double = 0
    private var held = false
    /// How long a press has to last to be a hold rather than a click.
    private static let holdAfter: TimeInterval = 0.35

    private var panLast: CGPoint = .zero
    private var verticalCarry: CGFloat = 0
    private var panAxis: NSLayoutConstraint.Axis?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityTraits = .button
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        addGestureRecognizer(pan)
        #if os(iOS)
        // On a touch screen: a tap shows or hides the controls, a double tap
        // on either side skips, the way every video app on iPad does.
        let double = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
        double.numberOfTapsRequired = 2
        addGestureRecognizer(double)
        let single = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        single.require(toFail: double)
        addGestureRecognizer(single)
        #endif
    }

    #if os(iOS)
    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        actions.touch(Double(tap.location(in: self).x / max(bounds.width, 1)))
    }

    @objc private func doubleTapped(_ tap: UITapGestureRecognizer) {
        actions.doubleTouch(Double(tap.location(in: self).x / max(bounds.width, 1)))
    }
    #endif

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var canBecomeFocused: Bool { true }

    /// Pressing up at the picture makes UIKit look for something above it,
    /// and with nothing there it lets focus fall to nothing, after which no
    /// press reaches the player and back closes it. Focus may go to something
    /// real (the Up Next card), never to nothing.
    override func shouldUpdateFocus(in context: UIFocusUpdateContext) -> Bool {
        if context.previouslyFocusedItem === self, context.nextFocusedItem == nil { return false }
        return super.shouldUpdateFocus(in: context)
    }

    override func didUpdateFocus(in context: UIFocusUpdateContext, with coordinator: UIFocusAnimationCoordinator) {
        super.didUpdateFocus(in: context, with: coordinator)
        // And if it does drop anyway, take it back.
        if context.previouslyFocusedItem === self, context.nextFocusedItem == nil {
            DispatchQueue.main.async { [weak self] in
                guard let window = self?.window else { return }
                window.setNeedsFocusUpdate()
                window.updateFocusIfNeeded()
            }
        }
    }

    /// Back from the row of buttons, the picture is the only thing left to
    /// focus, but UIKit doesn't look again until something asks it to.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window, !self.isFocused else { return }
            window.setNeedsFocusUpdate()
            window.updateFocusIfNeeded()
        }
    }

    // MARK: Presses

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            switch press.type {
            case .leftArrow: startHolding(-1)
            case .rightArrow: startHolding(1)
            case .upArrow: actions.up()
            case .downArrow: actions.down()
            case .playPause: actions.playPause()
            // Select is acted on when let go, the way a button is; back is
            // SwiftUI's.
            case .select, .menu: break
            default: unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            switch press.type {
            case .leftArrow, .rightArrow: finishHolding()
            case .select: actions.select()
            // Back is SwiftUI's (see PlayerChrome): acting here too would
            // take two steps for one press.
            case .menu, .upArrow, .downArrow, .playPause: break
            default: unhandled.insert(press)
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        stopHolding()
        super.pressesCancelled(presses, with: event)
    }

    private func startHolding(_ direction: Double) {
        stopHolding()
        holdDirection = direction
        holdStart = Date()
        held = false
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.holdTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func holdTick() {
        guard let holdStart else { return }
        let now = Date()
        let elapsed = now.timeIntervalSince(holdStart)
        guard elapsed >= Self.holdAfter else { return }
        let step = lastTick.map { now.timeIntervalSince($0) } ?? (1.0 / 30)
        lastTick = now
        held = true
        actions.hold(holdDirection, elapsed - Self.holdAfter, step)
    }

    /// Let go: a click if it never became a hold.
    private func finishHolding() {
        let wasHeld = held
        let direction = holdDirection
        stopHolding()
        if !wasHeld, direction != 0 { actions.tap(direction) }
    }

    func stopHolding() {
        holdTimer?.invalidate()
        holdTimer = nil
        holdStart = nil
        lastTick = nil
        held = false
        holdDirection = 0
    }

    // MARK: Swipes

    /// Sideways scrubs, a little at a time as the finger moves; up or down
    /// counts as the arrow, once for every stretch of finger. The first clear
    /// direction a swipe takes is the one it keeps.
    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let point = pan.translation(in: self)
        switch pan.state {
        case .began:
            panLast = point
            panAxis = nil
        case .changed:
            if panAxis == nil {
                if abs(point.x) > 30, abs(point.x) > abs(point.y) {
                    panAxis = .horizontal
                } else if abs(point.y) > 30, abs(point.y) > abs(point.x) {
                    panAxis = .vertical
                    verticalCarry = 0
                }
            }
            switch panAxis {
            case .horizontal:
                actions.swipe(point.x - panLast.x)
            case .vertical:
                // A step up or down for every stretch of finger, so a swipe
                // runs down a menu the way the arrows do, one line at a time.
                verticalCarry += point.y - panLast.y
                while abs(verticalCarry) >= 80 {
                    if verticalCarry < 0 { actions.up(); verticalCarry += 80 } else { actions.down(); verticalCarry -= 80 }
                }
            default:
                break
            }
            panLast = point
        default:
            panAxis = nil
        }
    }
}

#endif

enum PlayerClock {
    static func clock(_ seconds: Double) -> String {
        let total = Int(max(seconds, 0).rounded(.down))
        let (h, m, s) = (total / 3600, total / 60 % 60, total % 60)
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /// "+2:30" or "−0:40": how far the mark is from where the film is now.
    static func delta(_ seconds: Double) -> String {
        (seconds < 0 ? "−" : "+") + clock(abs(seconds))
    }
}

/// The film end to end: what has played, a tick where each chapter starts,
/// a recording's commercial breaks in a paler shade of the scheme's colour,
/// and, while scrubbing, a mark where the viewer is heading.
private struct Timeline: View {
    let position: Double
    let target: Double?
    let duration: Double
    let chapters: [Chapter]
    var breaks: [SkipSegment] = []

    /// A break's colour: the scheme's own, lightened. The programme is the
    /// darker of the two all along the bar, played or not.
    private var breakTint: Color { Theme.accent.mix(with: .white, by: 0.6) }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let mid = geometry.size.height / 2
            let played = fraction(position)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22)).frame(height: 8)
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent, Theme.accentSecondary],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(width * played, 8), height: 8)
                if let target {
                    // The stretch between here and the mark, so the distance
                    // reads at a glance rather than by comparing two numbers.
                    let aim = fraction(target)
                    Capsule()
                        .fill(Theme.accent.opacity(0.55))
                        .frame(width: width * abs(aim - played), height: 8)
                        .offset(x: width * min(aim, played))
                }
                // A recording's breaks, over all of that: to be seen coming,
                // and scrubbed past. Full strength as far as it has played,
                // as the bar itself is.
                bands(width: width, upTo: 1, fill: breakTint.opacity(0.8))
                bands(width: width, upTo: played, fill: breakTint)
                // Where each chapter begins. The first begins at the start,
                // where a tick would say nothing.
                ForEach(Array(chapters.enumerated()), id: \.offset) { _, chapter in
                    if chapter.startSeconds > 1, duration > 0, chapter.startSeconds < duration - 1 {
                        Capsule()
                            .fill(.white.opacity(0.55))
                            .frame(width: 3, height: 16)
                            .position(x: width * fraction(chapter.startSeconds), y: mid)
                    }
                }
                if let target {
                    Capsule()
                        .fill(.white)
                        .frame(width: 6, height: 30)
                        .shadow(color: .black.opacity(0.5), radius: 6)
                        .position(x: width * fraction(target), y: mid)
                } else {
                    Circle()
                        .fill(.white)
                        .frame(width: 20, height: 20)
                        .shadow(color: Theme.accent.opacity(0.8), radius: 10)
                        .position(x: width * played, y: mid)
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(height: 30)
        .animation(.easeOut(duration: 0.12), value: target)
    }

    private func fraction(_ seconds: Double) -> Double {
        duration > 0 ? min(max(seconds / duration, 0), 1) : 0
    }

    /// The breaks as stretches of the bar, as far along it as `limit` (a
    /// fraction of the whole), and cut to its rounded ends.
    private func bands(width: CGFloat, upTo limit: Double, fill: Color) -> some View {
        ZStack(alignment: .leading) {
            Color.clear
            ForEach(breaks) { marked in
                let from = fraction(marked.start)
                // Never too narrow to see on a long recording.
                let whole = max(width * (fraction(marked.end) - from), 3)
                let shown = min(whole, width * (limit - from))
                if duration > 0, marked.end > marked.start, shown > 0 {
                    Rectangle()
                        .fill(fill)
                        .frame(width: shown, height: 8)
                        .offset(x: width * from)
                }
            }
        }
        .frame(width: width, height: 8)
        .clipShape(Capsule())
    }
}

/// Where a scrub will land, riding above the mark: the server's trickplay
/// frame for that moment when it has made them, and always the chapter and
/// time underneath.
private struct ScrubPreview: View {
    let trickplay: Trickplay?
    let target: Double
    let duration: Double
    let caption: String
    /// Kept while the next sheet loads, so the frame doesn't blink out.
    @State private var shown: CGImage?

    private var imageSize: CGSize? {
        guard let info = trickplay?.info else { return nil }
        let width = CGFloat(360).scaled
        return CGSize(width: width, height: width * CGFloat(info.height) / CGFloat(max(info.width, 1)))
    }

    private var height: CGFloat { (imageSize.map { $0.height + 14 } ?? 0) + 34 }

    var body: some View {
        let frame = trickplay?.frame(at: target)
        GeometryReader { geometry in
            let aim = duration > 0 ? min(max(target / duration, 0), 1) : 0
            let half = max(imageSize?.width ?? 220, 220) / 2
            VStack(spacing: 14) {
                if let imageSize {
                    Group {
                        if let shown {
                            Image(decorative: shown, scale: 1).resizable()
                        } else {
                            Color.black.opacity(0.4)
                        }
                    }
                    .frame(width: imageSize.width, height: imageSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white, lineWidth: 3))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                }
                Text(caption)
                    .font(.app(22, .bold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.black.opacity(0.55)))
            }
            .fixedSize()
            .position(x: min(max(geometry.size.width * aim, half), geometry.size.width - half),
                      y: height / 2)
        }
        .frame(height: height)
        .task(id: frame.map { "\($0.sheet)#\($0.column)x\($0.row)" }) {
            guard let frame, let info = trickplay?.info else { return }
            let sheet = TrickplaySheets.cached(frame.sheet)
            let loaded = sheet == nil ? await TrickplaySheets.load(frame.sheet) : sheet
            guard let loaded, !Task.isCancelled else { return }
            shown = Self.cut(loaded, column: frame.column, row: frame.row, info: info)
        }
        .accessibilityHidden(true)
    }

    /// Sheets can arrive smaller than their stated size, so cells are measured
    /// from the sheet itself.
    private static func cut(_ sheet: CGImage, column: Int, row: Int, info: TrickplayInfo) -> CGImage? {
        let cellWidth = sheet.width / max(info.tileWidth, 1)
        let cellHeight = sheet.height / max(info.tileHeight, 1)
        return sheet.cropping(to: CGRect(x: column * cellWidth, y: row * cellHeight,
                                         width: cellWidth, height: cellHeight))
    }
}

#if os(iOS)
import AVKit

/// The system's AirPlay picker, as a button.
private struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Theme.accent)
        picker.prioritizesVideoDevices = true
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#endif
