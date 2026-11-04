import AVKit
import SwiftUI

// MARK: - Now Playing

/// The song playing, whole-screen: its cover, where it's up to, the
/// controls, and beside them its words or what's to come. Put away, the
/// music plays on.
struct NowPlayingView: View {
    @Environment(\.appState) private var app
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var music = MusicPlayer.shared
    @State private var panel: Panel?
    @FocusState private var focus: Control?
    /// The song asked to go into a playlist, while one is chosen.
    @State private var adding: PlaylistAddition?

    enum Panel { case lyrics, queue, chapters }
    enum Control: Hashable { case shuffle, previous, playPause, next, repeating, lyrics, queue, chapters, speed }

    var body: some View {
        ZStack {
            if let song = music.current {
                #if os(tvOS)
                television(song)
                #else
                handheld(song)
                #endif
            } else {
                Text("Nothing playing.", comment: "Now Playing with the queue emptied")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Behind, not beside: the cover filling the screen is wider than a
        // phone held upright, and laid beside the rest it made the whole
        // screen as wide.
        .background { backdrop }
        #if os(tvOS)
        .onPlayPauseCommand { music.togglePause() }
        .defaultFocus($focus, .playPause)
        #endif
        .onChange(of: music.isActive) { _, active in if !active { dismiss() } }
        .fullScreenCover(item: $adding) { addition in
            PlaylistPicker(addition: addition)
                .presentationBackground(.clear)
        }
        .onChange(of: music.lyrics == nil) { _, none in if none, panel == .lyrics { panel = nil } }
    }

    /// The cover, huge and blurred, darkened enough to read on.
    private var backdrop: some View {
        ZStack {
            Theme.background
            if let song = music.current {
                Color.clear
                    .overlay {
                        RemoteImage(url: app?.client?.imageURL(for: song, type: "Primary", maxWidth: 400), symbol: "music.note")
                            .blur(radius: 70)
                            .scaleEffect(1.3)
                    }
                    .clipped()
                    .opacity(0.75)
                    .id(song.albumId ?? song.id)
                    .transition(.opacity)
            }
            LinearGradient(colors: [.black.opacity(0.25), .black.opacity(0.7)], startPoint: .top, endPoint: .bottom)
        }
        .animation(.easeInOut(duration: 0.6), value: music.current?.albumId ?? music.current?.id)
        .ignoresSafeArea()
    }

    private func cover(_ song: BaseItem, side: CGFloat) -> some View {
        MusicArt(item: song, maxWidth: 900)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side > 200 ? 18 : 10))
            .shadow(color: .black.opacity(0.5), radius: side > 200 ? 40 : 12, y: side > 200 ? 18 : 6)
            .scaleEffect(music.isPlaying || side < 200 ? 1 : 0.94)
            .animation(.spring(duration: 0.4), value: music.isPlaying)
    }

    private func about(_ song: BaseItem, alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 8) {
            // A book is its own source: said once, as the title.
            if let source = music.source, !music.isBook {
                Text(String(localized: "PLAYING FROM \(source.uppercased())", comment: "Now Playing: where the queue came from, in capitals"))
                    .font(.app(13, .heavy))
                    .kerning(1.4)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            Text(song.isAudiobook ? (song.album ?? song.displayTitle) : song.displayTitle)
                .font(.app(Theme.isPhone ? 26 : 40, .bold))
                .lineLimit(2)
                .multilineTextAlignment(alignment == .center ? .center : .leading)
            if song.isAudiobook {
                if let author = song.byLine {
                    Text(author)
                        .font(.app(Theme.isPhone ? 19 : 26, .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
                ChapterLine(song: song)
            } else if let artist = song.byLine {
                Text(artist)
                    .font(.app(Theme.isPhone ? 19 : 26, .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
            if !song.isAudiobook, let album = song.album {
                Text([album, song.productionYear.map(String.init)].compactMap { $0 }.joined(separator: " · "))
                    .font(.app(Theme.isPhone ? 15 : 20))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var controls: some View {
        HStack(spacing: Theme.isPhone ? 0 : 22) {
            if music.isBook {
                bookControls
            } else {
                songControls
            }
        }
    }

    /// An audiobook's: how fast, a quarter minute back, play, half a minute
    /// on, the next chapter.
    @ViewBuilder
    private var bookControls: some View {
        BookSpeedControl(focus: $focus)
        if Theme.isPhone { Spacer() }
        control(.previous, "gobackward.15", label: String(localized: "Back 15 Seconds", comment: "Audiobook: back a quarter of a minute")) { music.skip(by: -15) }
        if Theme.isPhone { Spacer() }
        playPause
        if Theme.isPhone { Spacer() }
        control(.next, "goforward.30", label: String(localized: "Forward 30 Seconds", comment: "Audiobook: on half a minute")) { music.skip(by: 30) }
        if Theme.isPhone { Spacer() }
        control(.repeating, "forward.end.fill", label: String(localized: "Next Chapter", comment: "Audiobook: on to the start of the next chapter")) { nextChapter() }
    }

    /// The next chapter of the one file, or the next part.
    private func nextChapter() {
        if music.queue.count == 1, let marks = music.current?.bookChapters,
           let next = marks.first(where: { $0.startSeconds > music.clock.position + 1 }) {
            music.seek(to: next.startSeconds)
        } else {
            music.next()
        }
    }

    private var playPause: some View {
        Button { music.togglePause() } label: {
            ZStack {
                if music.isWaiting && !music.isPlaying {
                    ProgressView().tint(.black)
                } else {
                    Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .font(.system(size: CGFloat(Theme.isPhone ? 30 : 34).scaled, weight: .bold))
            .frame(width: CGFloat(Theme.isPhone ? 74 : 96).scaled, height: CGFloat(Theme.isPhone ? 74 : 96).scaled)
        }
        .buttonStyle(PlayDiscStyle())
        .focused($focus, equals: .playPause)
        .accessibilityLabel(music.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
    }

    @ViewBuilder
    private var songControls: some View {
            control(.shuffle, "shuffle", active: music.isShuffled, label: String(localized: "Shuffle")) { music.toggleShuffle() }
            if Theme.isPhone { Spacer() }
            control(.previous, "backward.fill", label: String(localized: "Previous", comment: "Music: the song before")) { music.previous() }
            if Theme.isPhone { Spacer() }
            playPause
            if Theme.isPhone { Spacer() }
            control(.next, "forward.fill", label: String(localized: "Next", comment: "Music: the song after")) { music.next() }
            if Theme.isPhone { Spacer() }
            control(.repeating, music.repeatMode == .one ? "repeat.1" : "repeat", active: music.repeatMode != .off,
                    label: String(localized: "Repeat", comment: "Music: play the queue, or the song, again")) { music.cycleRepeat() }
    }

    private func control(_ id: Control, _ symbol: String, active: Bool = false, label: String,
                         action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: CGFloat(Theme.isPhone ? 22 : 26).scaled, weight: .semibold))
                .frame(width: CGFloat(Theme.isPhone ? 48 : 72).scaled, height: CGFloat(Theme.isPhone ? 48 : 72).scaled)
        }
        .buttonStyle(MusicControlStyle(active: active))
        .focused($focus, equals: id)
        .accessibilityLabel(label)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    /// Lyrics and Up Next, which open beside the controls; the sleep timer;
    /// and the song made a favourite, or put in a playlist. With their words
    /// where they fit, by their symbols alone where they don't (a television
    /// with lyrics on offer, an iPad on its side): squeezed, the words
    /// wrapped a few letters to a line.
    private func panels(_ song: BaseItem) -> some View {
        ViewThatFits(in: .horizontal) {
            panels(song, iconsOnly: Theme.isPhone)
            panels(song, iconsOnly: true)
        }
    }

    private func panels(_ song: BaseItem, iconsOnly: Bool) -> some View {
        HStack(spacing: 16) {
            if song.isAudiobook {
                if music.queue.count > 1 || song.bookChapters.count > 1 {
                    panelButton(.chapters, symbol: "list.bullet", title: String(localized: "Chapters", comment: "Heading over an audiobook's chapters"),
                                iconOnly: iconsOnly)
                }
                MusicSleepButton(iconOnly: iconsOnly)
                MusicFavoriteButton(item: song)
            } else {
            if music.lyrics != nil {
                panelButton(.lyrics, symbol: "quote.bubble", title: String(localized: "Lyrics", comment: "Now Playing: shows the song's words"),
                            iconOnly: iconsOnly)
            }
            panelButton(.queue, symbol: "list.bullet", title: String(localized: "Up Next", comment: "Now Playing: the songs to come"),
                        iconOnly: iconsOnly)
            MusicSleepButton(iconOnly: iconsOnly)
            MusicFavoriteButton(item: song)
            Button {
                adding = PlaylistAddition(item: song) { [song] }
            } label: {
                Image(systemName: "text.badge.plus")
            }
            .buttonStyle(.action(active: false))
            .accessibilityLabel(String(localized: "Add to Playlist", comment: "Puts songs in a playlist, chosen next"))
            }
        }
    }

    private func panelButton(_ which: Panel, symbol: String, title: String, iconOnly: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.25)) { panel = panel == which ? nil : which }
        } label: {
            Label(title, systemImage: symbol)
                // A phone's row hasn't the width for the words beside the
                // star and the playlist button: the symbol alone there.
                .labelStyle(SleepLabelStyle(compact: iconOnly))
        }
        .buttonStyle(.pill(selected: panel == which))
        .focused($focus, equals: which == .lyrics ? .lyrics : which == .chapters ? .chapters : .queue)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private func panelContent(_ which: Panel) -> some View {
        switch which {
        case .lyrics:
            if let lyrics = music.lyrics { LyricsPanel(lyrics: lyrics) }
        case .queue:
            QueuePanel()
        case .chapters:
            ChaptersPanel()
        }
    }

    #if os(tvOS)
    private func television(_ song: BaseItem) -> some View {
        HStack(alignment: .center, spacing: 90) {
            Group {
                if let panel {
                    panelContent(panel)
                        .frame(width: 820)
                        .transition(.opacity)
                } else {
                    cover(song, side: 620)
                        .transition(.opacity)
                }
            }
            .frame(width: 820, height: 860)
            .focusSection()
            VStack(alignment: .leading, spacing: 34) {
                if panel != nil { cover(song, side: 180) }
                about(song, alignment: .leading)
                NowPlayingProgress(clock: music.clock, seeks: false)
                    .frame(maxWidth: 760)
                controls
                panels(song)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusSection()
        }
        .padding(.horizontal, 100)
    }
    #else
    private func handheld(_ song: BaseItem) -> some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height && geometry.size.width > 700
            let side = min(geometry.size.width - 64, geometry.size.height * (wide ? 0.62 : 0.42), 440)
            Group {
                if wide {
                    HStack(spacing: 48) {
                        Group {
                            if let panel { panelContent(panel) } else { cover(song, side: side) }
                        }
                        .frame(width: max(side, geometry.size.width * 0.42))
                        // Clear of the close chevron at the top left, which
                        // sat over the panel's heading.
                        .padding(.top, Theme.isPhone ? 0 : 76)
                        stack(song, side: side, showsCover: false)
                    }
                } else {
                    stack(song, side: side, showsCover: true)
                }
            }
            .padding(.horizontal, 28)
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .overlay(alignment: .topLeading) {
            // A tablet's has no card to draw down.
            if !Theme.isPhone {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 20, weight: .semibold))
                        .frame(width: 44, height: 44)
                        .background(.white.opacity(0.12), in: Circle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .padding(20)
                .accessibilityLabel(String(localized: "Close"))
            }
        }
        .presentationDragIndicator(.visible)
    }

    private func stack(_ song: BaseItem, side: CGFloat, showsCover: Bool) -> some View {
        VStack(spacing: 22) {
            if showsCover {
                if let panel {
                    HStack(spacing: 14) {
                        cover(song, side: 64)
                        about(song, alignment: .leading)
                        Spacer(minLength: 0)
                    }
                    panelContent(panel)
                        .frame(maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                    cover(song, side: side)
                    Spacer(minLength: 0)
                    about(song, alignment: .center)
                }
            } else {
                about(song, alignment: .center)
            }
            NowPlayingProgress(clock: music.clock, seeks: true)
            controls
            HStack {
                panels(song)
                Spacer()
                RoutePicker()
                    .frame(width: 44, height: 44)
            }
        }
        // Below the close button on a tablet.
        .padding(.top, Theme.isPhone ? 30 : 76)
        .padding(.bottom, 16)
    }
    #endif
}

/// The chapter playing of an audiobook in one file, or the part playing of
/// one in parts. Its own view: it follows the clock.
private struct ChapterLine: View {
    @ObservedObject private var clock = MusicPlayer.shared.clock
    let song: BaseItem

    var body: some View {
        if let line = ChaptersPanel.current(of: song, at: clock.position)?.name ?? (MusicPlayer.shared.queue.count > 1 ? song.displayTitle : nil) {
            Text(line)
                .font(.app(Theme.isPhone ? 15 : 20))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
    }
}

/// How fast an audiobook plays: chosen from a menu by touch, a press at a
/// time on a television.
private struct BookSpeedControl: View {
    @ObservedObject private var music = MusicPlayer.shared
    var focus: FocusState<NowPlayingView.Control?>.Binding

    private func label(_ speed: Float) -> String { speed.formatted(.number.precision(.fractionLength(0...2))) + "×" }

    var body: some View {
        #if os(tvOS)
        Button {
            let all = MusicPlayer.bookSpeeds
            music.setBookSpeed(all[((all.firstIndex(of: music.bookSpeed) ?? 1) + 1) % all.count])
        } label: {
            Text(label(music.bookSpeed))
                .font(.system(size: CGFloat(22).scaled, weight: .bold))
                .monospacedDigit()
                .frame(width: CGFloat(72).scaled, height: CGFloat(72).scaled)
        }
        .buttonStyle(MusicControlStyle(active: music.bookSpeed != 1))
        .focused(focus, equals: .speed)
        .accessibilityLabel(String(localized: "Speed", comment: "Heading over the list of playback speeds"))
        .accessibilityValue(label(music.bookSpeed))
        #else
        Menu {
            Picker(String(localized: "Speed", comment: "Heading over the list of playback speeds"),
                   selection: Binding(get: { music.bookSpeed }, set: { music.setBookSpeed($0) })) {
                ForEach(MusicPlayer.bookSpeeds, id: \.self) { Text(label($0)).tag($0) }
            }
        } label: {
            Text(label(music.bookSpeed))
                .font(.system(size: 17, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(music.bookSpeed != 1 ? Theme.primary.1 : .white)
                .frame(width: 48, height: 48)
        }
        .accessibilityLabel(String(localized: "Speed", comment: "Heading over the list of playback speeds"))
        .accessibilityValue(label(music.bookSpeed))
        #endif
    }
}

/// An audiobook's chapters (or parts): chosen, it goes there.
private struct ChaptersPanel: View {
    @ObservedObject private var music = MusicPlayer.shared
    @ObservedObject private var clock = MusicPlayer.shared.clock

    /// The chapter of a file a moment is in.
    static func current(of song: BaseItem, at seconds: Double) -> Chapter? {
        let marks = song.bookChapters
        guard marks.count > 1 else { return nil }
        return marks.last { $0.startSeconds <= seconds + 0.5 }
    }

    private struct Row: Identifiable {
        let id: Int
        let title: String
        let part: Int
        let start: Double
    }

    private var rows: [Row] {
        if music.queue.count > 1 {
            return music.queue.enumerated().map { Row(id: $0.offset, title: $0.element.song.displayTitle, part: $0.offset, start: 0) }
        }
        let marks = music.current?.bookChapters ?? []
        return marks.enumerated().map { Row(id: $0.offset, title: $0.element.name ?? "", part: 0, start: $0.element.startSeconds) }
    }

    private var playing: Int? {
        if music.queue.count > 1 { return music.index }
        guard let song = music.current, let now = Self.current(of: song, at: clock.position) else { return nil }
        return song.bookChapters.firstIndex(of: now)
    }

    var body: some View {
        let rows = rows
        let playing = playing
        VStack(alignment: .leading, spacing: 12) {
            Text("Chapters", comment: "Heading over an audiobook's chapters")
                .font(.app(Theme.isPhone ? 20 : 28, .bold))
                .padding(.leading, 14)
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(rows) { row in
                        Button {
                            if row.part != music.index { music.jump(to: row.part) } else { music.seek(to: row.start) }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.app(15, .bold))
                                    .opacity(row.id == playing ? 1 : 0)
                                    .frame(width: 24)
                                Text(row.title)
                                    .font(.app(Theme.isPhone ? 17 : 22, .semibold))
                                    .lineLimit(1)
                                Spacer(minLength: 8)
                                if music.queue.count == 1 {
                                    Text(NowPlayingProgress.time(row.start))
                                        .font(.app(Theme.isPhone ? 14 : 17))
                                        .monospacedDigit()
                                        .opacity(0.6)
                                }
                            }
                        }
                        .buttonStyle(TrackRowStyle())
                    }
                }
                .padding(.vertical, 20)
                .padding(.horizontal, 10)
            }
        }
    }
}

/// The sleep timer, the app's one: off, a length of time, or the end of
/// the song playing.
private struct MusicSleepButton: View {
    @ObservedObject private var timer = SleepTimer.shared
    /// The moon alone, the row having no room for words.
    var iconOnly = Theme.isPhone

    var body: some View {
        Menu {
            Button(String(localized: "Off", comment: "Subtitles turned off")) { timer.cancel() }
            ForEach(SleepTimer.lengths, id: \.self) { minutes in
                Button(SleepTimer.length(minutes)) { timer.set(minutes: minutes) }
            }
            Button(String(localized: "When This Song Ends", comment: "Sleep timer choice: stop when the song playing ends")) { timer.setAtEnd() }
        } label: {
            Label(timer.isSet ? (timer.atEnd ? String(localized: "End of Song", comment: "Sleep timer set to stop when the song playing ends") : timer.summary())
                              : SleepTimer.title,
                  systemImage: timer.isSet ? "moon.zzz.fill" : "moon.zzz")
                .labelStyle(SleepLabelStyle(compact: iconOnly && !(Theme.isPhone && timer.isSet)))
        }
        .buttonStyle(.pill(selected: timer.isSet))
        .accessibilityLabel(SleepTimer.title)
    }
}

/// On a phone, the moon alone until it's set.
private struct SleepLabelStyle: LabelStyle {
    let compact: Bool

    func makeBody(configuration: Configuration) -> some View {
        if compact { configuration.icon } else { Label(configuration).lineLimit(1) }
    }
}

/// The play/pause disc: white with a dark symbol, whatever the focus.
private struct PlayDiscStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(Circle().fill(.white))
            .shadow(color: .black.opacity(focused ? 0.5 : 0.25), radius: focused ? 24 : 10, y: 6)
            .scaleEffect(focused ? 1.12 : configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// A round control: white with focus, the scheme's colour while on (shuffle, repeat).
struct MusicControlStyle: ButtonStyle {
    var active = false
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(focused ? Color.black : active ? Theme.primary.1 : .white)
            .background(Circle().fill(focused ? Color.white : active ? Color.white.opacity(0.14) : .clear))
            .scaleEffect(focused ? 1.1 : configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// Where the song's up to, and how long it is. On a phone or a tablet the
/// bar is dragged to move through the song.
struct NowPlayingProgress: View {
    @ObservedObject var clock: MusicClock
    let seeks: Bool
    @State private var dragging: Double?

    var body: some View {
        let length = max(clock.duration, 0.1)
        let shown = dragging ?? clock.position
        VStack(spacing: 8) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white)
                        .frame(width: max(0, min(1, shown / length)) * geometry.size.width)
                }
                .frame(height: dragging == nil ? 6 : 10)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                #if !os(tvOS)
                .gesture(seeks ? DragGesture(minimumDistance: 0)
                    .onChanged { dragging = max(0, min(1, $0.location.x / geometry.size.width)) * length }
                    .onEnded { _ in
                        if let dragging { MusicPlayer.shared.seek(to: dragging) }
                        dragging = nil
                    } : nil)
                #endif
            }
            .frame(height: 22)
            .animation(.easeOut(duration: 0.15), value: dragging == nil)
            HStack {
                Text(Self.time(shown))
                Spacer()
                Text("-" + Self.time(max(0, length - shown)))
            }
            .font(.app(Theme.isPhone ? 13 : 17, .medium))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.65))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(localized: "\(Self.time(shown)) of \(Self.time(length))", comment: "Music: how far into the song, of its length"))
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let whole = Int(seconds)
        return whole >= 3600 ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
                             : String(format: "%d:%02d", whole / 60, whole % 60)
    }
}

/// A song's words, the line being sung lit and kept in view where they're
/// timed; a timed line chosen goes to it.
private struct LyricsPanel: View {
    let lyrics: Lyrics
    @ObservedObject private var clock = MusicPlayer.shared.clock

    private var currentLine: Int? {
        guard lyrics.isSynced else { return nil }
        let ticks = Int64(clock.position * 10_000_000)
        return lyrics.lyrics.lastIndex { ($0.start ?? 0) <= ticks }
    }

    var body: some View {
        let current = currentLine
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: Theme.isPhone ? 14 : 22) {
                    ForEach(Array(lyrics.lyrics.enumerated()), id: \.offset) { place, line in
                        Button {
                            if lyrics.isSynced, let start = line.start { MusicPlayer.shared.seek(to: Double(start) / 10_000_000) }
                        } label: {
                            Text(line.text?.isEmpty == false ? line.text! : "♪")
                                .font(.app(Theme.isPhone ? 24 : 36, .bold))
                                .foregroundStyle(.white.opacity(current == nil || current == place ? 1 : 0.35))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(LyricLineStyle())
                        .id(place)
                    }
                }
                .padding(.vertical, Theme.isPhone ? 20 : 200)
            }
            .onChange(of: current) { _, line in
                guard let line else { return }
                withAnimation(.easeInOut(duration: 0.5)) { proxy.scrollTo(line, anchor: .center) }
            }
            .onAppear { if let current { proxy.scrollTo(current, anchor: .center) } }
        }
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.12),
                                     .init(color: .black, location: 0.88), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

private struct LyricLineStyle: ButtonStyle {
    @Environment(\.isFocused) private var focused

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(.white.opacity(focused ? 0.16 : 0)))
            .scaleEffect(focused ? 1.03 : 1, anchor: .leading)
            .animation(.easeOut(duration: 0.14), value: focused)
    }
}

/// What's to come, in order: chosen, a song plays from there; on a phone or
/// a tablet, songs are dragged to reorder and swiped away.
private struct QueuePanel: View {
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        let coming = Array(music.upNext)
        VStack(alignment: .leading, spacing: 12) {
            Text("Up Next", comment: "Now Playing: the songs to come")
                .font(.app(Theme.isPhone ? 20 : 28, .bold))
                .padding(.leading, 14)
            if coming.isEmpty {
                Text(music.repeatMode == .all ? String(localized: "The queue starts again after this song.")
                                              : String(localized: "Nothing after this song."))
                    .font(.app(17))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.leading, 14)
                    #if os(tvOS)
                    .focusable()
                    #endif
                Spacer(minLength: 0)
            } else {
                #if os(tvOS)
                ScrollView(showsIndicators: false) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(coming) { entry in
                            TrackRow(song: entry.song, showsArtist: true) {
                                if let place = music.queue.firstIndex(of: entry) { music.jump(to: place) }
                            }
                        }
                    }
                    .padding(.vertical, 20)
                    .padding(.horizontal, 10)
                }
                #else
                List {
                    ForEach(coming) { entry in
                        TrackRow(song: entry.song, showsArtist: true) {
                            if let place = music.queue.firstIndex(of: entry) { music.jump(to: place) }
                        }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                    }
                    .onDelete { offsets in
                        for offset in offsets where coming.indices.contains(offset) { music.remove(coming[offset]) }
                    }
                    .onMove { music.move(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                #endif
            }
        }
    }
}

#if os(macOS)
/// AirPlay: where the sound goes, the Mac's own button.
private struct RoutePicker: NSViewRepresentable {
    func makeNSView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.isRoutePickerButtonBordered = false
        picker.setRoutePickerButtonColor(.white, for: .normal)
        picker.setRoutePickerButtonColor(NSColor(Theme.primary.1), for: .active)
        return picker
    }

    func updateNSView(_ nsView: AVRoutePickerView, context: Context) {}
}
#endif

#if os(iOS)
/// AirPlay: where the sound goes.
private struct RoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.tintColor = .white
        picker.activeTintColor = UIColor(Theme.primary.1)
        picker.prioritizesVideoDevices = false
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

#if !os(tvOS)
/// The song playing, along the foot of the screen above the tabs: its
/// cover, its name, play/pause and next. Tapped, Now Playing opens.
struct MiniPlayer: View {
    @Environment(\.appState) private var app
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        Group {
            if let song = music.current { bar(song) }
        }
        .animation(.easeOut(duration: 0.25), value: music.current == nil)
    }

    private func bar(_ song: BaseItem) -> some View {
        HStack(spacing: 12) {
            MusicArt(item: song, maxWidth: 160)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                Text(song.displayTitle)
                    .font(.app(16, .semibold))
                    .lineLimit(1)
                if let artist = song.byLine {
                    Text(artist)
                        .font(.app(13))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            Button { music.togglePause() } label: {
                Image(systemName: music.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 44, height: 44)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(music.isPlaying ? String(localized: "Pause") : String(localized: "Play"))
            // A book goes on half a minute; music to the next song.
            if music.isBook {
                Button { music.skip(by: 30) } label: {
                    Image(systemName: "goforward.30")
                        .font(.system(size: 21, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "Forward 30 Seconds", comment: "Audiobook: on half a minute"))
            } else {
                Button { music.next() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel(String(localized: "Next", comment: "Music: the song after"))
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 8)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
                .overlay(alignment: .bottom) { MiniProgress(clock: music.clock).padding(.horizontal, 14) }
                .shadow(color: .black.opacity(0.35), radius: 14, y: 4)
        }
        .contentShape(Rectangle())
        .onTapGesture { music.showsNowPlaying = true }
        .padding(.horizontal, 10)
        .padding(.bottom, 6)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

private struct MiniProgress: View {
    @ObservedObject var clock: MusicClock

    var body: some View {
        GeometryReader { geometry in
            Capsule().fill(Theme.primary.1)
                .frame(width: geometry.size.width * (clock.duration > 0 ? min(1, clock.position / clock.duration) : 0))
        }
        .frame(height: 2)
    }
}
#endif

/// Puts Now Playing up when it's asked for, from wherever. Its own view, so
/// the player's changes redraw it alone and not the screen it's on.
struct NowPlayingPresenter: View {
    @ObservedObject private var music = MusicPlayer.shared

    var body: some View {
        Color.clear
            #if os(tvOS)
            .fullScreenCover(isPresented: $music.showsNowPlaying) { NowPlayingView() }
            #else
            // A card drawn down over the page on a phone; on a tablet, the
            // whole screen, which a card there was too short for.
            .sheet(isPresented: Binding(get: { music.showsNowPlaying && Theme.isPhone }, set: { music.showsNowPlaying = $0 })) {
                NowPlayingView()
            }
            .fullScreenCover(isPresented: Binding(get: { music.showsNowPlaying && !Theme.isPhone }, set: { music.showsNowPlaying = $0 })) {
                NowPlayingView()
            }
            #endif
    }
}

#if os(tvOS)
/// The menu's Now Playing row, at its top while there's music.
struct NowPlayingMenuRow: View {
    @ObservedObject private var music = MusicPlayer.shared
    let expanded: Bool
    var focus: FocusState<MainTabView.SidebarItem?>.Binding

    var body: some View {
        if music.isActive {
            SidebarRow(title: String(localized: "Now Playing", comment: "Menu row: the music playing"),
                       icon: music.isPlaying ? "speaker.wave.2.fill" : "speaker.fill",
                       selected: false, expanded: expanded, id: .nowPlaying, focus: focus) {
                music.showsNowPlaying = true
            }
        }
    }
}
#endif
