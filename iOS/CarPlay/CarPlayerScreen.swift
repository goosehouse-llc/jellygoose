import AVFoundation
import SwiftUI

/// The picture on the car's screen, full screen, with CarTV's controls: back
/// and the title along the top, play and the skips in the middle, the
/// timeline and Fit along the foot. A touch shows them; they go after a few
/// seconds of playing.
///
/// While the car limits its screen (driving) the picture waits behind a card
/// and the sound carries on.
struct CarPlayerScreen: View {
    @ObservedObject var model: CarScreenModel
    @State private var controlsShown = true
    /// A car's screen is wider than a film: filled to begin with.
    @State private var fills = true
    /// Where the timeline's knob is while it's being dragged, in seconds.
    @State private var scrubbing: Double?
    @State private var panel: Panel?
    @State private var tracks: CarPlayPlayer.Tracks?
    @State private var lastTouch = Date()

    private enum Panel { case tracks, channels }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let player = CarPlayPlayer.shared
            ZStack {
                Color.black.ignoresSafeArea()
                if model.driving {
                    drivingCard
                } else if model.isLive {
                    // Not touched itself: VLC's view would take the touch
                    // that brings the controls back.
                    CarLivePicture(tuner: model.tuner)
                        .allowsHitTesting(false)
                } else {
                    CarVideo(player: player.avPlayer, fills: fills)
                        .allowsHitTesting(false)
                }
                if let trouble = trouble(player) {
                    Text(trouble)
                        .font(.app(15, .semibold))
                        .multilineTextAlignment(.center)
                        .padding(30)
                } else if waiting(player) {
                    ProgressView().controlSize(.large).tint(.white)
                }
                if controlsShown || model.driving {
                    controls(player)
                        .transition(.opacity)
                }
                if let panel {
                    HStack {
                        Spacer()
                        Group {
                            switch panel {
                            case .tracks: tracksPanel
                            case .channels: channelsPanel
                            }
                        }
                        .frame(width: 240)
                        .background(Color(white: 0.12).opacity(0.97))
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeOut(duration: 0.2)) {
                    if panel != nil { panel = nil } else { controlsShown.toggle() }
                }
                lastTouch = Date()
            }
            .onChange(of: context.date) { _, now in
                // Out of the way after five seconds of playing untouched.
                if controlsShown, panel == nil, scrubbing == nil, !model.isPaused, trouble(player) == nil,
                   now.timeIntervalSince(lastTouch) > 5 {
                    withAnimation(.easeOut(duration: 0.3)) { controlsShown = false }
                }
            }
        }
        .foregroundStyle(.white)
    }

    /// Still coming: the server readying a film, a tuner being found.
    private func waiting(_ player: CarPlayPlayer) -> Bool {
        if model.isLive { return model.tuner.phase == .tuning }
        if model.starting != nil { return true }
        return (player.avPlayer?.currentItem?.status ?? .unknown) == .unknown
    }

    private func trouble(_ player: CarPlayPlayer) -> String? {
        if model.isLive { return model.liveTrouble }
        if model.starting == nil, player.avPlayer?.currentItem?.status == .failed {
            return String(localized: "Couldn't play this", comment: "Shown on the car's display when a title won't start")
        }
        return nil
    }

    // MARK: Controls

    private func controls(_ player: CarPlayPlayer) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                circle("chevron.left", size: 16) { model.showsPlayer = false }
                VStack(alignment: .leading, spacing: 1) {
                    Text(model.starting ?? model.playing?.title ?? "").font(.app(16, .bold)).lineLimit(1)
                    if let subtitle = model.playing?.subtitle, model.starting == nil {
                        Text(subtitle).font(.app(12, .semibold)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                circle("xmark", size: 15) { model.stop() }
            }
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 24)
            .background(LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom))

            Spacer(minLength: 0)
            HStack(spacing: 36) {
                if model.isLive {
                    circle("chevron.down", size: 20, label: String(localized: "Channel down", comment: "Button: the previous television channel")) {
                        model.changeChannel(by: -1)
                    }
                } else {
                    circle("gobackward.10", size: 20) { Task { await player.skip(by: -10) } }
                }
                Button { model.togglePause(); lastTouch = Date() } label: {
                    Image(systemName: model.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 30, weight: .bold))
                        .frame(width: 64, height: 64)
                        .background(Circle().fill(.white.opacity(0.18)))
                }
                .buttonStyle(CarPress())
                if model.isLive {
                    circle("chevron.up", size: 20, label: String(localized: "Channel up", comment: "Button: the next television channel")) {
                        model.changeChannel(by: 1)
                    }
                } else {
                    circle("goforward.30", size: 20) { Task { await player.skip(by: 30) } }
                }
            }
            Spacer(minLength: 0)

            VStack(spacing: 6) {
                if !model.isLive, let duration = player.duration, duration > 0 {
                    timeline(position: scrubbing ?? player.position, duration: duration, player: player)
                }
                HStack(spacing: 16) {
                    if model.isLive {
                        chip("list.bullet", String(localized: "Channels", comment: "On the car's display: opens the list of channels while one plays")) {
                            panel = .channels
                        }
                    } else {
                        chip("captions.bubble", String(localized: "Audio and Subtitles",
                                                       comment: "On the car's display: opens the choice of audio track and subtitle")) {
                            Task {
                                if let item = player.current, let client = model.client {
                                    tracks = await player.tracks(for: item, client: client)
                                }
                                panel = .tracks
                            }
                        }
                    }
                    Spacer(minLength: 0)
                    if !model.isLive, player.hasNext {
                        chip("forward.end.fill", String(localized: "Next Episode", comment: "On the car's display: plays the episode after this one")) { Task { await player.next() } }
                    }
                    chip(fills ? "rectangle.arrowtriangle.2.inward" : "rectangle.arrowtriangle.2.outward",
                         fills ? String(localized: "Fit", comment: "On the car's display: shows the whole picture, with bars")
                               : String(localized: "Fill", comment: "On the car's display: fills the screen with the picture, cropping it")) {
                        fills.toggle()
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 24)
            .padding(.bottom, 10)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom))
        }
    }

    private func timeline(position: Double, duration: Double, player: CarPlayPlayer) -> some View {
        HStack(spacing: 10) {
            Text(Self.clock(position)).font(.app(12, .semibold)).monospacedDigit()
            GeometryReader { geometry in
                let fraction = min(max(position / duration, 0), 1)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.3)).frame(height: 4)
                    Capsule().fill(Theme.accent).frame(width: geometry.size.width * fraction, height: 4)
                    Circle().fill(.white).frame(width: 18, height: 18)
                        .offset(x: geometry.size.width * fraction - 9)
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        scrubbing = min(max(drag.location.x / geometry.size.width, 0), 1) * duration
                        lastTouch = Date()
                    }
                    .onEnded { _ in
                        guard let target = scrubbing else { return }
                        Task {
                            await player.seek(to: target)
                            scrubbing = nil
                        }
                    })
            }
            .frame(height: 24)
            Text("-" + Self.clock(max(0, duration - position))).font(.app(12, .semibold)).monospacedDigit()
        }
    }

    private func circle(_ symbol: String, size: CGFloat, label: String? = nil, action: @escaping () -> Void) -> some View {
        Button {
            action()
            lastTouch = Date()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .bold))
                .frame(width: size * 2.2, height: size * 2.2)
                .background(Circle().fill(.white.opacity(0.14)))
        }
        .buttonStyle(CarPress())
        .accessibilityLabel(label ?? "")
    }

    private func chip(_ symbol: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button {
            action()
            lastTouch = Date()
        } label: {
            Label(title, systemImage: symbol)
                .font(.app(13, .semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(.white.opacity(0.14)))
        }
        .buttonStyle(CarPress())
    }

    private var drivingCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "car.side").font(.system(size: 34))
            Text(String(localized: "The picture comes back when you're parked. The sound carries on.",
                        comment: "On the car's display, in place of the picture while the car is moving"))
                .font(.app(15, .semibold))
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.75))
        .padding(30)
    }

    // MARK: Panels

    private var tracksPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                if let tracks, let item = CarPlayPlayer.shared.current {
                    if tracks.audio.count > 1 {
                        heading(String(localized: "Audio", comment: "Heading over the list of audio tracks"))
                        ForEach(tracks.audio.compactMap { stream in stream.index.map { (stream, $0) } }, id: \.1) { stream, index in
                            option(Self.name(stream), chosen: index == tracks.chosenAudio) {
                                await CarPlayPlayer.shared.choose(audio: index, for: item.id)
                            }
                        }
                    }
                    heading(String(localized: "Subtitles"))
                    option(String(localized: "Off", comment: "Subtitles are turned off"),
                           chosen: tracks.chosenSubtitle == PlaybackContext.subtitlesOff) {
                        await CarPlayPlayer.shared.choose(subtitle: PlaybackContext.subtitlesOff, for: item.id)
                    }
                    ForEach(tracks.subtitles.compactMap { stream in stream.index.map { (stream, $0) } }, id: \.1) { stream, index in
                        option(Self.name(stream), chosen: index == tracks.chosenSubtitle) {
                            await CarPlayPlayer.shared.choose(subtitle: index, for: item.id)
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    private var channelsPanel: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(model.channels) { channel in
                    Button {
                        panel = nil
                        model.tune(channel)
                    } label: {
                        HStack(spacing: 8) {
                            RemoteImage(url: model.logoURL(channel), contentMode: .fit).frame(width: 36, height: 24)
                            Text([channel.number, channel.name].compactMap { $0 }.joined(separator: " "))
                                .font(.app(13, model.liveChannel?.id == channel.id ? .bold : .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(CarPress())
                }
            }
            .padding(12)
        }
    }

    private func heading(_ text: String) -> some View {
        Text(text).font(.app(12, .bold)).foregroundStyle(.white.opacity(0.5)).padding(.top, 6)
    }

    private func option(_ title: String, chosen: Bool, pick: @escaping () async -> Void) -> some View {
        Button {
            Task {
                await pick()
                // The tick moves to the new choice.
                if let item = CarPlayPlayer.shared.current, let client = model.client {
                    tracks = await CarPlayPlayer.shared.tracks(for: item, client: client)
                }
            }
        } label: {
            HStack {
                Text(title).font(.app(13, .semibold)).lineLimit(1)
                Spacer(minLength: 0)
                if chosen { Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)) }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(CarPress())
    }

    private static func name(_ stream: MediaStream) -> String {
        stream.displayTitle ?? stream.title ?? stream.language ?? String(localized: "Unknown")
    }

    /// "1:02:03", "4:05".
    private static func clock(_ seconds: Double) -> String {
        let total = Int(seconds.isFinite ? max(0, seconds) : 0)
        let hours = total / 3600, minutes = total / 60 % 60, rest = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest) : String(format: "%d:%02d", minutes, rest)
    }
}

/// The player's picture, drawn into the car's window.
private struct CarVideo: UIViewRepresentable {
    let player: AVPlayer?
    let fills: Bool

    func makeUIView(context: Context) -> VideoView {
        let view = VideoView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: VideoView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
        view.playerLayer.videoGravity = fills ? .resizeAspectFill : .resizeAspect
    }

    final class VideoView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

/// The channel's picture (the tuner's one view, see `LiveSurface`), taking
/// no touches: VLC's view would keep the tap that brings the controls back.
private struct CarLivePicture: UIViewRepresentable {
    let tuner: LiveTuner

    func makeUIView(context: Context) -> LiveSurfaceHost {
        let host = LiveSurfaceHost()
        host.backgroundColor = .clear
        host.isUserInteractionEnabled = false
        return host
    }

    func updateUIView(_ host: LiveSurfaceHost, context: Context) {
        host.adopt(tuner.surface)
    }
}

/// Over the phone's own player when it's on the car's screen (a film started
/// on the phone): the same rule as the car's player, the picture only while
/// parked. The phone's controls are under it, so it has its own way out.
struct CarDrivingCover: View {
    @ObservedObject var car: CarScreenModel

    var body: some View {
        if car.driving {
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                VStack(spacing: 10) {
                    Image(systemName: "car.side").font(.system(size: 34))
                    Text(String(localized: "The picture comes back when you're parked. The sound carries on.",
                                comment: "On the car's display, in place of the picture while the car is moving"))
                        .font(.app(15, .semibold))
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(30)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Closed the way the player's own button closes it, where
                // the film got to filed.
                Button { PlayerStage.shared.askToClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(.white.opacity(0.14)))
                }
                .buttonStyle(CarPress())
                .padding(12)
            }
        }
    }
}

/// The phone's player on the car's screen: laid out as on a phone held on
/// its side, then shrunk to the room beside CarPlay's column down the side
/// of the screen, controls and all, so it fits as it does on the phone.
struct CarFit<Content: View>: View {
    /// What CarPlay covers at the screen's edges (its column, on the left).
    let clear: UIEdgeInsets
    @ViewBuilder let content: Content

    /// A phone on its side, in points, near enough.
    private static var phone: CGSize { CGSize(width: 760, height: 420) }

    var body: some View {
        GeometryReader { geometry in
            let room = CGSize(width: geometry.size.width - clear.left - clear.right,
                              height: geometry.size.height - clear.top - clear.bottom)
            let scale = min(1, room.width / Self.phone.width, room.height / Self.phone.height)
            content
                .frame(width: room.width / scale, height: room.height / scale)
                .scaleEffect(scale)
                .frame(width: room.width, height: room.height)
                .clipped()
                .position(x: clear.left + room.width / 2, y: clear.top + room.height / 2)
        }
        .background(Color.black)
    }
}
