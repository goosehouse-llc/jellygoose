import Foundation

/// Settings → Dashboard: what the server is doing, for its administrators, as
/// its own web dashboard shows it. Read every few seconds while it's open.

/// One device's session on the server, with what it's playing.
struct ServerSession: Decodable, Identifiable, Equatable {
    struct PlayState: Decodable, Equatable {
        let positionTicks: Int64?
        let isPaused: Bool?
        /// "DirectPlay", "DirectStream" or "Transcode".
        let playMethod: String?
    }

    let id: String
    let userName: String?
    /// The app: "Jellyfin Web", "JellyGoose".
    let client: String?
    let deviceName: String?
    let nowPlayingItem: BaseItem?
    let playState: PlayState?
    let transcodingInfo: TranscodingInfo?
    /// Whether the app there takes playback commands (Stop) from the server.
    let supportsRemoteControl: Bool?
    /// The general commands it takes: "DisplayMessage" for a message.
    let supportedCommands: [String]?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.nowPlayingItem?.id == rhs.nowPlayingItem?.id && lhs.playState == rhs.playState
            && lhs.transcodingInfo == rhs.transcodingInfo && lhs.supportsRemoteControl == rhs.supportsRemoteControl
            && lhs.supportedCommands == rhs.supportedCommands
    }

    /// Whether the server is repackaging or re-encoding it, rather than sending the file.
    var isConverted: Bool { (playState?.playMethod ?? "DirectPlay") != "DirectPlay" }

    /// Whether Stop Playback reaches it: an app that doesn't take commands
    /// (or isn't connected) is offered nothing, as the server's own dashboard
    /// does, rather than a button that does nothing.
    var canStop: Bool { supportsRemoteControl == true }

    /// Whether a message shows there: an app that shows them, connected now
    /// (the server remembers what a device takes after it has gone).
    var canMessage: Bool { canStop && supportedCommands?.contains("DisplayMessage") == true }
}

/// One line of the server's activity log.
struct ActivityEntry: Decodable, Identifiable, Equatable {
    let id: Int64
    let name: String
    let shortOverview: String?
    let type: String?
    let date: String?
    /// "Information", "Warning", "Error".
    let severity: String?

    var when: Date? { date.flatMap(ServerDates.parse) }
}

struct ActivityPage: Decodable {
    let items: [ActivityEntry]
}

/// One of the server's scheduled tasks.
struct ScheduledTask: Decodable, Identifiable, Equatable {
    struct LastRun: Decodable, Equatable {
        let endTimeUtc: String?
        /// "Completed", "Failed", "Cancelled", "Aborted".
        let status: String?
    }

    let id: String
    let name: String
    /// "Idle", "Running", "Cancelling".
    let state: String
    let currentProgressPercentage: Double?
    let category: String?
    let isHidden: Bool?
    let lastExecutionResult: LastRun?

    var isRunning: Bool { state != "Idle" }
}

/// What the server says of itself.
struct ServerSystemInfo: Decodable, Equatable {
    let serverName: String?
    let version: String?
    let operatingSystemDisplayName: String?
    let hasUpdateAvailable: Bool?
    let hasPendingRestart: Bool?
}

/// The server's dates: ISO 8601, with or without fractions of a second, and
/// sometimes more of them than the formatter takes.
enum ServerDates {
    nonisolated(unsafe) private static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) private static let plain = ISO8601DateFormatter()

    static func parse(_ text: String) -> Date? {
        if let date = withFractions.date(from: text) ?? plain.date(from: text) { return date }
        // "2026-10-28T19:00:00.1234567Z": seven places, cut to three.
        guard let dot = text.firstIndex(of: ".") else { return nil }
        let digits = text[text.index(after: dot)...].prefix { $0.isNumber }
        let trimmed = text[..<dot] + "." + digits.prefix(3) + text[text.index(after: dot)...].dropFirst(digits.count)
        return withFractions.date(from: String(trimmed))
    }
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var info: ServerSystemInfo?
    @Published private(set) var sessions: [ServerSession] = []
    @Published private(set) var tasks: [ScheduledTask] = []
    @Published private(set) var activity: [ActivityEntry] = []
    @Published private(set) var loaded = false
    @Published private(set) var note: String?
    /// The session or task a request is being made for.
    @Published private(set) var working: String?

    private var lastSlowRead = Date.distantPast
    /// Whether the note says the server couldn't be read (gone at the next
    /// good read), rather than how something asked for went (kept a while).
    private var noteFromReading = false
    private var noteShownAt = Date.distantPast

    private func show(_ text: String, fromReading: Bool) {
        note = text
        noteFromReading = fromReading
        noteShownAt = Date()
    }

    /// Who's playing something, by name.
    var playing: [ServerSession] {
        sessions.filter { $0.nowPlayingItem != nil }
            .sorted { ($0.userName ?? "").localizedStandardCompare($1.userName ?? "") == .orderedAscending }
    }

    /// The tasks the server shows: those running first, then by kind and name.
    var shownTasks: [ScheduledTask] {
        tasks.filter { $0.isHidden != true }
            .sorted { ($0.isRunning ? 0 : 1, $0.category ?? "", $0.name) < ($1.isRunning ? 0 : 1, $1.category ?? "", $1.name) }
    }

    /// Sessions and tasks every time; the log and the server's own details
    /// every quarter of a minute.
    func refresh(_ client: MediaBrowserClient) async {
        do {
            // Asked together: each is a round trip, and the page waits on all of them.
            async let now = client.dashboardSessions()
            async let running = client.scheduledTasks()
            let slow = Date().timeIntervalSince(lastSlowRead) > 15
            async let log = slow ? client.activityLog(limit: 40) : nil
            async let about = slow ? client.dashboardInfo() : nil
            let (sessionsNow, tasksNow) = try await (now, running)
            if sessionsNow != sessions { sessions = sessionsNow }
            if tasksNow != tasks { tasks = tasksNow }
            if slow {
                lastSlowRead = Date()
                if let entries = try await log, entries != activity { activity = entries }
                if let details = try await about, details != info { info = details }
            }
            // A read that failed before is forgotten; how something asked for
            // went stays long enough to be read.
            if note != nil, working == nil, noteFromReading || Date().timeIntervalSince(noteShownAt) > 8 { note = nil }
        } catch {
            show(String(localized: "Couldn't read the server: \(error.localizedDescription)",
                        comment: "Settings, Dashboard: the server didn't answer; the placeholder is what went wrong"),
                 fromReading: true)
        }
        loaded = true
    }

    func run(_ task: ScheduledTask, client: MediaBrowserClient) async {
        await act(task.id, client: client) {
            if task.isRunning { try await client.stopTask(task.id) } else { try await client.runTask(task.id) }
        }
    }

    func stop(_ session: ServerSession, client: MediaBrowserClient) async {
        await act(session.id, client: client) { try await client.stopPlayback(session: session.id) }
    }

    func message(_ session: ServerSession, text: String, client: MediaBrowserClient) async {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await act(session.id, client: client) {
            try await client.sendMessage(session: session.id, text: text)
            show(String(localized: "Sent to \(session.deviceName ?? session.client ?? "").",
                        comment: "Settings, Dashboard: a message was sent; the placeholder is the device it went to"),
                 fromReading: false)
        }
    }

    private func act(_ id: String, client: MediaBrowserClient, _ work: () async throws -> Void) async {
        working = id
        do {
            try await work()
        } catch {
            show(String(localized: "The server refused: \(error.localizedDescription)",
                        comment: "Settings, Dashboard: a stop, run or message failed; the placeholder is what went wrong"),
                 fromReading: false)
        }
        // A moment for the server to take it in before it's read again.
        try? await Task.sleep(for: .seconds(1))
        working = nil
        await refresh(client)
    }
}
