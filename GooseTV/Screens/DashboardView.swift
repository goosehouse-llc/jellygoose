import SwiftUI

/// Settings → Dashboard, for a Jellyfin server's administrators: who's watching
/// what and how it reaches them (with a way to stop it or send a message), the
/// server's scheduled tasks (run or stop), and its activity log. Read every few
/// seconds while it's open.
struct DashboardView: View {
    @EnvironmentObject var app: AppState
    @StateObject private var model = DashboardModel()
    @State private var stopping: ServerSession?
    @State private var messaging: ServerSession?

    private var client: MediaBrowserClient? { app.client as? MediaBrowserClient }

    var body: some View {
        SettingsPage(title: String(localized: "Dashboard", comment: "Settings tile and page: what the server is doing, for its administrators"),
                     accent: Theme.palette[1]) {
            if let info = model.info { serverLine(info) }
            if let note = model.note {
                SettingsNote(note, tint: Theme.primary.1)
            }
            SettingsColumn(alignment: .leading) {
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120).focusable()
                } else {
                    DashboardHeading(String(localized: "NOW PLAYING", comment: "Settings, Dashboard: heading over who's watching what, in capitals"))
                    if model.playing.isEmpty {
                        Text("Nobody is watching anything right now.", comment: "Settings, Dashboard: no session is playing")
                            .font(.app(17))
                            .foregroundStyle(Theme.textSecondary)
                            .focusable()
                    }
                    ForEach(model.playing) { session in
                        SessionCard(session: session, busy: model.working == session.id) {
                            messaging = session
                        } stop: {
                            stopping = session
                        }
                    }

                    DashboardHeading(String(localized: "SCHEDULED TASKS", comment: "Settings, Dashboard: heading over the server's tasks, in capitals"))
                    ForEach(model.shownTasks) { task in
                        TaskRow(task: task, busy: model.working == task.id) {
                            guard let client else { return }
                            Task { await model.run(task, client: client) }
                        }
                    }

                    DashboardHeading(String(localized: "ACTIVITY", comment: "Settings, Dashboard: heading over the server's activity log, in capitals"))
                    ForEach(model.activity) { ActivityRow(entry: $0) }
                }
            }
        }
        .task {
            guard let client else { return }
            while !Task.isCancelled {
                await model.refresh(client)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .confirmationDialog(String(localized: "Stop what's playing on \(stopping?.deviceName ?? "")?",
                                   comment: "Settings, Dashboard: confirming a stop; the placeholder is the device"),
                            isPresented: $stopping.isPresent(), titleVisibility: .visible) {
            Button(String(localized: "Stop Playback", comment: "Settings, Dashboard: stops what a device is playing"), role: .destructive) {
                if let session = stopping, let client { Task { await model.stop(session, client: client) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It stops as if they'd stopped it themselves, where they got to kept.",
                 comment: "Settings, Dashboard: what stopping someone's playback means")
        }
        .fullScreenCover(item: $messaging) { session in
            TextEntryPanel(title: String(localized: "Message to \(session.deviceName ?? session.client ?? "")",
                                         comment: "Settings, Dashboard: title of the panel for writing a message; the placeholder is the device"),
                           message: String(localized: "It shows over what they're watching for ten seconds.",
                                           comment: "Settings, Dashboard: what sending a message does"),
                           placeholder: String(localized: "Message", comment: "Settings, Dashboard: placeholder in the message field"),
                           action: String(localized: "Send", comment: "Settings, Dashboard: sends the message")) { text in
                guard let client else { return }
                await model.message(session, text: text, client: client)
            }
            .presentationBackground(.clear)
        }
    }

    /// "Media Server · Jellyfin 12.2.0 · macOS", and anything waiting.
    private func serverLine(_ info: ServerSystemInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text([info.serverName, info.version.map { "Jellyfin \($0)" }, info.operatingSystemDisplayName]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.app(17, .semibold))
                .foregroundStyle(Theme.textSecondary)
            if info.hasPendingRestart == true {
                Label(String(localized: "The server is waiting to restart.", comment: "Settings, Dashboard: the server needs a restart to finish a change"),
                      systemImage: "arrow.clockwise.circle.fill")
                    .font(.app(16, .semibold))
                    .foregroundStyle(Theme.palette[1].0)
            }
            if info.hasUpdateAvailable == true {
                Label(String(localized: "A newer version of the server is out.", comment: "Settings, Dashboard: the server says there's an update"),
                      systemImage: "arrow.down.circle.fill")
                    .font(.app(16, .semibold))
                    .foregroundStyle(Theme.primary.1)
            }
        }
    }
}

private struct DashboardHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(.app(12, .heavy))
            .kerning(1.6)
            .foregroundStyle(Theme.palette[1].1)
            .padding(.top, 10)
    }
}

/// Someone watching: what, where, how far in, how it reaches them, and the
/// two things to do about it.
private struct SessionCard: View {
    let session: ServerSession
    let busy: Bool
    let message: () -> Void
    let stop: () -> Void

    var body: some View {
        let item = session.nowPlayingItem
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                if let item, item.isEpisode {
                    Text([item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                        .font(.app(14, .semibold))
                        .foregroundStyle(Theme.primary.1)
                        .lineLimit(1)
                }
                Text(item?.displayTitle ?? "")
                    .font(.app(20, .semibold))
                    .lineLimit(2)
                Text(who)
                    .font(.app(15))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            if let fraction {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: fraction)
                        .tint(Theme.accent)
                    Text(whereAt)
                        .font(.app(14))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Text(how)
                .font(.app(14, .semibold))
                .foregroundStyle(session.isConverted ? Theme.palette[1].1 : Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            // Only what the app there takes: one that doesn't (or isn't
            // connected) would be sent a stop or a message that never arrives.
            if session.canMessage || session.canStop {
                // Not disabled while busy, only deaf: on a TV, focus coming back
                // from the message panel found them disabled and went to a task's
                // Run button instead, where the next press would run it.
                HStack(spacing: 12) {
                    if session.canMessage {
                        Button(String(localized: "Send Message", comment: "Settings, Dashboard: writes a message to show on a device")) {
                            if !busy { message() }
                        }
                        .buttonStyle(.chip(active: false))
                    }
                    if session.canStop {
                        Button(String(localized: "Stop Playback", comment: "Settings, Dashboard: stops what a device is playing")) {
                            if !busy { stop() }
                        }
                        .buttonStyle(.chip(active: false))
                    }
                    if busy { ProgressView() }
                }
                // The card's whole width: on a TV, up from the tasks' Run
                // buttons (at the far right) has to land here.
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvFocusSection()
            } else {
                Text("This app can't be sent a message or stopped from here.",
                     comment: "Settings, Dashboard: under someone's playback, when their app takes no commands from the server")
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
                    .focusable()
            }
        }
        .padding(.horizontal, CGFloat(22).scaled)
        .padding(.vertical, CGFloat(18).scaled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    /// "Sam on Living Room · JellyGoose".
    private var who: String {
        let place = [session.deviceName, session.client].compactMap { $0 }.joined(separator: " · ")
        guard let user = session.userName else { return place }
        return String(localized: "\(user) on \(place)", comment: "Settings, Dashboard: who's watching where; the placeholders are a person and their device")
    }

    private var fraction: Double? {
        guard let length = session.nowPlayingItem?.runTimeTicks, length > 0 else { return nil }
        return min(Double(session.playState?.positionTicks ?? 0) / Double(length), 1)
    }

    /// "12:03 of 45:10 · Paused".
    private var whereAt: String {
        let at = Double(session.playState?.positionTicks ?? 0) / 10_000_000
        let length = Double(session.nowPlayingItem?.runTimeTicks ?? 0) / 10_000_000
        var parts = [String(localized: "\(PlayerClock.clock(at)) of \(PlayerClock.clock(length))", comment: "Download progress, like 1.2 GB of 4.5 GB")]
        if session.playState?.isPaused == true { parts.append(String(localized: "Paused", comment: "Settings, Dashboard: what someone's watching is paused")) }
        return parts.joined(separator: " · ")
    }

    /// "Direct play", or "Transcoded by the server · DTS audio · 8.2 Mbps".
    private var how: String {
        var parts = [PlaybackStats.method(converted: session.isConverted, session.transcodingInfo)]
        if let transcoding = session.transcodingInfo {
            let streams = session.nowPlayingItem?.mediaStreams
            let reasons = PlaybackStats.reasons(transcoding.reasons, source: nil,
                                                video: streams?.first { $0.type == "Video" },
                                                audio: streams?.first { $0.type == "Audio" },
                                                container: session.nowPlayingItem?.container)
            if !reasons.isEmpty { parts.append(reasons) }
            if let bitrate = transcoding.bitrate, bitrate > 0 { parts.append(PlaybackStats.mbps(Double(bitrate))) }
        }
        return parts.joined(separator: " · ")
    }
}

/// One scheduled task: what state it's in, and Run or Stop.
private struct TaskRow: View {
    let task: ScheduledTask
    let busy: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(task.name)
                    .font(.app(18, .semibold))
                    .lineLimit(1)
                if task.isRunning {
                    ProgressView(value: (task.currentProgressPercentage ?? 0) / 100)
                        .tint(Theme.accent)
                        .frame(maxWidth: 260)
                }
                Text(state)
                    .font(.app(14))
                    .foregroundStyle(task.lastExecutionResult?.status == "Failed" && !task.isRunning ? Theme.palette[1].1 : Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if busy { ProgressView() }
            // Deaf while busy rather than disabled: on a TV, focus leaves a
            // disabled button for the next task's Run, and the next press runs it.
            Button(task.isRunning ? String(localized: "Stop", comment: "Settings, Dashboard: stops a running task")
                                  : String(localized: "Run", comment: "Settings, Dashboard: runs a scheduled task now")) {
                if !busy { action() }
            }
            .buttonStyle(.chip(active: !task.isRunning))
        }
        .padding(.horizontal, CGFloat(22).scaled)
        .padding(.vertical, CGFloat(14).scaled)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }

    /// "Running · 42%", "Completed 2 hours ago", "Never run".
    private var state: String {
        if task.isRunning {
            return String(localized: "Running · \(Int(task.currentProgressPercentage ?? 0))%", comment: "Settings, Dashboard: a task under way; the placeholder is how far, in percent")
        }
        guard let result = task.lastExecutionResult, let end = result.endTimeUtc.flatMap(ServerDates.parse) else {
            return String(localized: "Never run", comment: "Settings, Dashboard: a task that hasn't run yet")
        }
        let when = DashboardTime.ago(end)
        return switch result.status {
        case "Failed": String(localized: "Failed \(when)", comment: "Settings, Dashboard: a task's last run failed; the placeholder is when, like 2 hours ago")
        case "Cancelled", "Aborted": String(localized: "Stopped \(when)", comment: "Settings, Dashboard: a task's last run was stopped; the placeholder is when, like 2 hours ago")
        default: String(localized: "Done \(when)", comment: "Settings, Dashboard: a task last ran to the end; the placeholder is when, like 2 hours ago")
        }
    }
}

/// One line of the activity log.
private struct ActivityRow: View {
    let entry: ActivityEntry

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.app(16, .semibold))
                .foregroundStyle(entry.severity == "Error" ? Theme.palette[1].0 : (entry.severity == "Warning" ? Theme.palette[1].1 : Theme.textSecondary))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.app(16, .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let overview = entry.shortOverview, !overview.isEmpty {
                    Text(overview)
                        .font(.app(14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            if let when = entry.when {
                Text(DashboardTime.ago(when))
                    .font(.app(13))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 6)
        // Read as one line: what happened, and when.
        .accessibilityElement(children: .combine)
        // On the Apple TV the log is moved through, line by line.
        .focusable()
    }

    private var icon: String {
        switch entry.severity {
        case "Error": "exclamationmark.triangle.fill"
        case "Warning": "exclamationmark.circle.fill"
        default:
            switch entry.type {
            case let type? where type.contains("Playback"): "play.circle"
            case let type? where type.contains("Authentication") || type.contains("Session"): "person.circle"
            default: "circle.fill"
            }
        }
    }
}

enum DashboardTime {
    /// "2 hours ago", in the viewer's language.
    static func ago(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        // The server's clock a moment ahead of this one read "in 0 seconds".
        let now = Date()
        return formatter.localizedString(for: min(date, now), relativeTo: now)
    }
}
