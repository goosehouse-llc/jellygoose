import SwiftUI

/// Play on TV: a film or episode chosen here, played on an Apple TV (or
/// anything else the server can play on: Jellyfin's web app in a browser,
/// another app), then worked from here like a remote. The server does the
/// telling (see `RemoteControl` for the Apple TV's side); this lists the
/// devices it says this account can play on, and asks.
struct PlayOnSheet: View {
    @Environment(\.appState) private var app
    @Environment(\.dismiss) private var dismiss
    /// What to play; nil to pick a TV to work what's already on it.
    let item: BaseItem?

    @State private var sessions: [RemoteSession]?
    @State private var failed = false
    @State private var path: [String] = []
    @State private var sending: String?
    @State private var playFailed = false

    var body: some View {
        NavigationStack(path: $path) {
            list
                .navigationTitle(Self.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(String(localized: "Done")) { dismiss() }
                    }
                }
                .navigationDestination(for: String.self) { id in
                    RemoteView(sessionId: id)
                }
        }
        #if os(macOS)
        // A sheet on the Mac is only as big as it's asked to be.
        .frame(minWidth: 520, minHeight: 620)
        #endif
        .task { await follow() }
        .alert(String(localized: "Couldn't play it there", comment: "Play on TV: the server didn't pass the film on to the TV chosen"),
               isPresented: $playFailed) {
            Button(String(localized: "OK")) {}
        } message: {
            Text(String(localized: "The TV may have closed JellyGoose. Try again, or choose another.", comment: "Play on TV: under the message that a film couldn't be sent to a TV"))
        }
    }

    @ViewBuilder
    private var list: some View {
        if let sessions, !sessions.isEmpty {
            List {
                if let item {
                    Section {
                        Text(String(localized: "Choose where to play \(item.displayTitle).", comment: "Play on TV: above the list of TVs. The placeholder is a film or episode"))
                            .font(.app(15))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(sessions) { session in
                    row(session)
                }
            }
        } else if sessions != nil || failed {
            ContentUnavailableView {
                Label(String(localized: "No TV is ready", comment: "Play on TV: no device the server could play on"), systemImage: "appletv")
            } description: {
                Text(String(localized: "Open JellyGoose on your Apple TV, signed in to the same account, and it appears here.", comment: "Play on TV: how to make a TV show up in the list"))
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func row(_ session: RemoteSession) -> some View {
        HStack(spacing: 14) {
            Button {
                if let item { Task { await play(item, on: session) } } else { path.append(session.id) }
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: session.client == "JellyGoose" ? "appletv.fill" : "play.tv")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.primary.1)
                        .frame(width: 34)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.deviceName ?? "Apple TV")
                            .font(.app(17, .semibold))
                        Text(Self.detail(of: session))
                            .font(.app(14))
                            .foregroundStyle(Theme.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(session.deviceName ?? "Apple TV")
            .accessibilityHint(Self.detail(of: session))
            if sending == session.id {
                ProgressView()
            } else if item == nil || session.nowPlayingItem != nil {
                // Working what's on it, without playing anything new.
                Button(String(localized: "Remote", comment: "Play on TV: opens the remote for a TV, to work what's playing on it")) {
                    path.append(session.id)
                }
                .buttonStyle(.bordered)
                .tint(Theme.primary.1)
            }
        }
        .padding(.vertical, 4)
    }

    private func play(_ item: BaseItem, on session: RemoteSession) async {
        guard let client = app?.client, sending == nil else { return }
        sending = session.id
        defer { sending = nil }
        do {
            try await client.play([item.id], on: session.id, startTicks: item.resumeTicks)
            path.append(session.id)
        } catch {
            playFailed = true
        }
    }

    /// The list, asked again every few seconds: a TV opened while this is up
    /// turns up in it.
    private func follow() async {
        while !Task.isCancelled {
            if let client = app?.client {
                do {
                    let mine = client.deviceId
                    sessions = try await client.controllableSessions()
                        .filter { $0.takesVideo && $0.deviceId != mine }
                } catch {
                    failed = true
                    if sessions == nil { sessions = [] }
                }
            }
            try? await Task.sleep(for: .seconds(4))
        }
    }

    static let title = String(localized: "Play on TV", comment: "Title of the list of TVs a film can be played on from the phone, and the button that opens it")

    /// Whose it is, and what's on it.
    static func detail(of session: RemoteSession) -> String {
        if let playing = session.nowPlayingItem {
            return String(localized: "Playing \(playing.seriesName ?? playing.displayTitle)", comment: "Play on TV: what a TV in the list is playing now. The placeholder is a film or show")
        }
        return session.userName ?? ""
    }
}

/// A remote for what's playing on another device: where it's got to, play
/// and pause, back and on, the soundtrack and subtitles, stop. Asked of the
/// server every second; between answers the position is carried on here.
struct RemoteView: View {
    @Environment(\.appState) private var app
    let sessionId: String

    @State private var session: RemoteSession?
    @State private var gone = false
    /// Where the device last said it was, and when that was heard.
    @State private var heard: (seconds: Double, at: Date)?
    @State private var paused = true
    /// The slider while a finger's on it.
    @State private var scrubbing: Double?
    /// Until when what the device says is ignored: a press here is shown at
    /// once, and its last word from before the press would undo it.
    @State private var trusting = Date.distantPast

    var body: some View {
        Group {
            if let item = session?.nowPlayingItem {
                playing(item)
            } else if session != nil || gone {
                ContentUnavailableView {
                    Label(String(localized: "Nothing is playing", comment: "Play on TV remote: the TV isn't playing anything"), systemImage: "appletv")
                } description: {
                    Text(session?.deviceName ?? "")
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle(session?.deviceName ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task { await follow() }
    }

    private func playing(_ item: BaseItem) -> some View {
        let duration = Double(item.runTimeTicks ?? 0) / 10_000_000
        return ScrollView {
            VStack(spacing: 22) {
                RemoteImage(url: picture(of: item))
                    .aspectRatio(16 / 9, contentMode: .fill)
                    .frame(maxWidth: .infinity)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                VStack(spacing: 4) {
                    Text(item.seriesName ?? item.displayTitle)
                        .font(.app(22, .bold))
                        .multilineTextAlignment(.center)
                    if let episode = item.episodeLabel {
                        Text("\(episode) · \(item.displayTitle)")
                            .font(.app(15))
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                }

                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let now = scrubbing ?? position(at: context.date)
                    VStack(spacing: 6) {
                        Slider(value: Binding(get: { min(now, max(duration, 1)) }, set: { scrubbing = $0 }),
                               in: 0...max(duration, 1)) { editing in
                            if !editing, let to = scrubbing { seek(to) }
                        }
                        .tint(Theme.primary.1)
                        HStack {
                            Text(PlayerClock.clock(now))
                            Spacer()
                            Text("−" + PlayerClock.clock(max(duration - now, 0)))
                        }
                        .font(.app(13).monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    }
                }

                HStack(spacing: 44) {
                    transport("gobackward.10", label: String(localized: "Back 10 seconds")) { skip(-10) }
                    transport(paused ? "play.fill" : "pause.fill", size: 34,
                              label: paused ? String(localized: "Play") : String(localized: "Pause")) { togglePause() }
                    transport("goforward.10", label: String(localized: "Forward 10 seconds")) { skip(10) }
                }

                HStack(spacing: 12) {
                    tracksMenu(String(localized: "Audio"), icon: "waveform", kind: "Audio", item: item)
                    tracksMenu(String(localized: "Subtitles"), icon: "captions.bubble", kind: "Subtitle", item: item)
                }
                Button(role: .destructive) {
                    send { try await $0.playstate("Stop", on: sessionId, seekTicks: nil) }
                } label: {
                    Label(String(localized: "Stop"), systemImage: "stop.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
        }
    }

    private func transport(_ symbol: String, size: CGFloat = 26, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 64, height: 64)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .accessibilityLabel(label)
    }

    /// The soundtracks or subtitles of what's playing, the one in use ticked.
    private func tracksMenu(_ title: String, icon: String, kind: String, item: BaseItem) -> some View {
        let streams = (item.mediaStreams ?? []).filter { $0.type == kind && $0.index != nil }
        let current = kind == "Audio" ? session?.playState?.audioStreamIndex : session?.playState?.subtitleStreamIndex
        let name = kind == "Audio" ? "SetAudioStreamIndex" : "SetSubtitleStreamIndex"
        return Menu {
            if kind == "Subtitle" {
                Button {
                    send { try await $0.command(name, on: sessionId, arguments: ["Index": "-1"]) }
                } label: {
                    if current == nil || current == -1 { Label(String(localized: "Off"), systemImage: "checkmark") } else { Text(String(localized: "Off")) }
                }
            }
            ForEach(streams, id: \.index) { stream in
                Button {
                    send { try await $0.command(name, on: sessionId, arguments: ["Index": "\(stream.index ?? 0)"]) }
                } label: {
                    if stream.index == current { Label(stream.trackName, systemImage: "checkmark") } else { Text(stream.trackName) }
                }
            }
        } label: {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(streams.isEmpty)
    }

    private func picture(of item: BaseItem) -> URL? {
        guard let client = app?.client else { return nil }
        if item.isEpisode, item.imageTags?["Primary"] != nil {
            return client.imageURL(for: item, type: "Primary", maxWidth: 1000)
        }
        return client.imageURL(for: item, type: "Backdrop", maxWidth: 1000)
            ?? client.imageURL(for: item, type: "Primary", maxWidth: 1000)
    }

    // MARK: Where it is

    /// Carried on from the last word while it plays: the device says where it
    /// is every few seconds, not every second.
    private func position(at date: Date) -> Double {
        guard let heard else { return 0 }
        return heard.seconds + (paused ? 0 : max(date.timeIntervalSince(heard.at), 0))
    }

    private func follow() async {
        while !Task.isCancelled {
            // A failed ask leaves things as they were: one lost on the way
            // isn't the TV gone.
            if let client = app?.client, let listed = try? await client.controllableSessions() {
                let found = listed.first { $0.id == sessionId }
                if let found, Date() < trusting {
                    session = found
                } else if let found {
                    let seconds = Double(found.playState?.positionTicks ?? 0) / 10_000_000
                    // Only a new word moves it: the same one again would drag it back.
                    // As of when it said so, not when this asked.
                    if heard.map({ abs($0.seconds - seconds) > 0.01 }) ?? true || found.playState?.isPaused != session?.playState?.isPaused {
                        heard = (seconds, min(found.checkedIn ?? Date(), Date()))
                    }
                    paused = found.playState?.isPaused ?? true
                    session = found
                } else {
                    gone = true
                    session = nil
                }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }

    // MARK: Asking

    private func togglePause() {
        // Shown at once; the device's word settles it after.
        heard = (position(at: Date()), Date())
        paused.toggle()
        trusting = Date().addingTimeInterval(4)
        send { try await $0.playstate("PlayPause", on: sessionId, seekTicks: nil) }
    }

    private func skip(_ seconds: Double) {
        seek(max(position(at: Date()) + seconds, 0))
    }

    private func seek(_ seconds: Double) {
        heard = (seconds, Date())
        scrubbing = nil
        trusting = Date().addingTimeInterval(4)
        send { try await $0.playstate("Seek", on: sessionId, seekTicks: Int64(seconds * 10_000_000)) }
    }

    private func send(_ ask: @escaping (any MediaServer) async throws -> Void) {
        guard let client = app?.client else { return }
        Task { try? await ask(client) }
    }
}
