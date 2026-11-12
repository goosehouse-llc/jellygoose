import SwiftUI

/// A channel on Home's row of what's on now: the programme's picture where
/// the listings came with one, the station's logo otherwise, with how far
/// through the programme is. Choosing it tunes the channel; a long press
/// offers to record what's on, as its place in the guide does.
struct LiveNowCard: View {
    @Environment(\.appState) private var app
    @Environment(\.sectionNavigator) private var navigator
    let item: BaseItem
    /// For a row that tracks and moves focus itself (the Apple TV's Home).
    var focus: FocusState<String?>.Binding? = nil
    var focusID: String? = nil
    var width: CGFloat = Theme.landscapeWidth
    let action: () -> Void

    private var program: LiveProgram? { item.currentProgram?.program }
    private var title: String { program?.name ?? item.displayTitle }
    /// The server wouldn't set a recording, or take one off: what to say.
    @State private var problem: String?
    /// The channel is being shown from the beginning of what's on, by the
    /// server's recording of it: the timer of that recording.
    @State private var fromStart: LiveStart?

    private struct LiveStart: Identifiable {
        let id: String
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: action) {
                ZStack(alignment: .bottom) {
                    picture
                        .frame(width: width, height: width * 9 / 16)
                        .clipped()
                    if let program, program.isOn() {
                        WatchProgressBar(fraction: program.fraction())
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                }
                .overlay(alignment: .topLeading) {
                    LiveBadge()
                        .scaleEffect(0.85, anchor: .topLeading)
                        .padding(10)
                }
                .overlay(alignment: .topTrailing) {
                    // Set to record, as the guide marks it.
                    if let program, program.isSetToRecord {
                        LiveRecordingDot(size: 11, says: program.recordingNote(at: Date()))
                            .padding(7)
                            .background(.black.opacity(0.55), in: Circle())
                            .padding(10)
                    }
                }
                .keepsCardCorners()
            }
            .buttonStyle(.tvCard)
            .focused(by: focus, id: focusID ?? item.id)
            .accessibilityLabel([title, item.liveChannelLine].joined(separator: ", "))
            .ownContextMenu(item, asked: recordingMenu)
            .alert(problem ?? "", isPresented: $problem.isPresent()) {}
            // A view of its own behind the card: the card has its menu to
            // present, and two things presented from the one view aren't
            // to be relied on.
            .background {
                Color.clear.fullScreenCover(item: $fromStart) { start in
                    if let client = app?.client { LiveWatchHost(channel: item, client: client, start: start.id) }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.app(17))
                    .lineLimit(1)
                Text(item.liveChannelLine)
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: width, alignment: .leading)
        }
        // What's on, looked for in the library ahead of a long press, whose
        // menu can't wait for it (asked once a name: see `libraryTitle`).
        .task(id: program?.name) {
            guard let app, let program, app.knownLibraryTitle(for: program) == nil else { return }
            _ = await app.libraryTitle(for: program)
        }
    }

    /// What a long press offers: the page of what's on, where the library
    /// has the show or the film; the recording of it, by the rules the guide
    /// goes by. Nothing for a channel with no listing to say what's on.
    private func recordingMenu() -> (heading: ItemMenuRequest.Heading, rows: [ItemMenuAction])? {
        guard let app, let client = app.client, let program else { return nil }
        let now = Date()
        var rows: [ItemMenuAction] = []
        if let title = app.knownLibraryTitle(for: program) ?? nil, !navigator.section.isEmpty {
            let navigator = navigator
            rows.append(ItemMenuAction(title: title.isSeries ? String(localized: "Go to Show") : String(localized: "Details"),
                                       icon: "info.circle") { navigator.showItem(title.id) })
        }
        // Anyone may watch what's being recorded from its start; the rest
        // is for an account that may record.
        let all = LiveTVModel.Recording.choices(for: program, at: now)
        let choices = app.liveCanRecord ? all : all.filter { $0 == .fromStart }
        rows += choices.map { choice in
            ItemMenuAction(title: choice.name(for: program, at: now),
                           icon: choice == .fromStart ? "backward.end" : choice.undoes ? "xmark.circle" : "record.circle",
                           destructive: choice.undoes) {
                if choice == .fromStart {
                    fromStart = program.timerId.map(LiveStart.init)
                    return
                }
                Task {
                    do {
                        try await choice.send(for: program, to: client)
                    } catch {
                        problem = choice.failure
                    }
                    // The row again: the server says what's recording now.
                    app.liveRecordingChanged()
                }
            }
        }
        let own = client.liveProgramImageURL(on: item, maxWidth: 400)
        return (ItemMenuRequest.Heading(eyebrow: item.liveChannelLine, title: program.name, detail: LiveClock.span(program),
                                        picture: own ?? client.imageURL(for: item, type: "Primary", maxWidth: 400), fits: own == nil),
                rows)
    }

    @ViewBuilder
    private var picture: some View {
        if let url = app?.client?.liveProgramImageURL(on: item, maxWidth: 800) {
            RemoteImage(url: url)
        } else {
            // No picture of the programme: the station's mark on the theme's
            // colour, or its name where it has no mark either.
            ZStack {
                Theme.gradient(Theme.primary, start: .topLeading, end: .bottomTrailing).opacity(0.4)
                if let logo = app?.client?.imageURL(for: item, type: "Primary", maxWidth: 400) {
                    RemoteImage(url: logo, contentMode: .fit)
                        .frame(width: width * 0.5, height: width * 9 / 16 * 0.55)
                } else {
                    Text(item.displayTitle)
                        .font(.app(22, .bold))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .padding(.horizontal, 16)
                }
            }
        }
    }
}

/// A channel chosen away from the guide (Home's row of what's on): the full
/// screen by itself, with a tuner of its own for as long as it's up. Back
/// returns to where it was chosen, and the tuner is let go.
struct LiveWatchHost: View {
    /// The channel; or a recording the server is still making, whose
    /// channel it is that's shown, from the recording's beginning.
    let channel: BaseItem
    let client: any MediaServer
    /// The timer of a recording of what's on the channel, to begin from the
    /// beginning of: the programme from its start, not as it goes out.
    var start: String? = nil
    /// The recording turned out to be over (it was listed while it was
    /// being made): it's a film now, and is played as one.
    var finished: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var model = LiveTVModel()

    var body: some View {
        LiveWatchView(model: model, tuner: model.tuner, highlight: model.highlight) { dismiss() }
            .task { await begin() }
            .onDisappear { model.tuner.stop() }
            .onChange(of: scenePhase) { _, phase in
                // Put away, the app lets the tuner go; back, it takes the channel up again.
                if phase == .background {
                    model.tuner.stop()
                } else if phase == .active, model.tuner.channelId == nil, !model.wallUp, let playing = model.highlight.playing {
                    model.tune(playing)
                }
            }
    }

    private func begin() async {
        // The channel first, from what Home already knew of it; then the
        // other channels and the guide, for the banner and for channel up
        // and down, which needn't hold the picture up.
        model.use(client)
        if channel.isLiveChannel {
            let live = LiveChannel(id: channel.id, name: channel.name ?? "", number: channel.channelNumber,
                                   isFavorite: channel.userData?.isFavorite ?? false,
                                   imageTag: channel.imageTags?["Primary"], now: channel.currentProgram?.program)
            if let start { model.fromStart(timer: start, on: live) } else { model.tune(live) }
        } else {
            // A recording, chosen among the recordings while it's still
            // being made: its channel, from the recording's first picture.
            guard let timer = channel.timerId, let found = await client.liveRecording(timerId: timer),
                  let id = found.channelId else {
                finished?()
                return
            }
            model.tune(LiveChannel(id: id, name: channel.channelName ?? "", number: nil, isFavorite: false, imageTag: nil, now: nil),
                       from: found.recording)
        }
        await model.load(from: client)
        // The channel as the server lists it, in place of the little that
        // was known of it from the recording.
        if let playing = model.highlight.playing, let listed = model.channels.first(where: { $0.id == playing.id }), listed != playing {
            model.highlight.playing = listed
        }
        // On the minute: what's on changes, and how far through it is. And
        // the guide again every few minutes, as the page does: read once, it
        // ran out some hours into an evening's watching, and the banner had
        // nothing to say.
        var minutes = 0
        while !Task.isCancelled {
            let seconds = 60 - Date().timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 60)
            try? await Task.sleep(for: .seconds(seconds + 0.5))
            if Task.isCancelled { break }
            minutes += 1
            if minutes % 5 == 0 { await model.load(from: client) } else { model.tick() }
        }
    }
}
