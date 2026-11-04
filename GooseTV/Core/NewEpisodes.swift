#if !os(tvOS)
import Foundation
import UserNotifications
#if os(iOS)
import BackgroundTasks
#endif

/// New-episode alerts: now and then, the server is asked what episodes it has
/// added since the last look, and a show the viewer watches (one they've seen
/// an episode of, have up next, or made a favourite) that has a new one gets a
/// notification, one a show, that opens it. Off until turned on in Settings,
/// which is when notifications are asked for.
///
/// When: on an iPhone or iPad, a background refresh iOS runs as it sees fit
/// (a few times a day for an app that's used); on a Mac, every hour while the
/// app is running. The Apple TV has no notifications to give.
@MainActor
final class NewEpisodes {
    static let shared = NewEpisodes()

    static let taskID = "com.goosehouse.jellygoose.newepisodes"
    static let enabledKey = "goosetv.newEpisodeAlerts"
    static var isOn: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    #if os(macOS)
    private var scheduler: NSBackgroundActivityScheduler?
    #endif

    // MARK: On and off

    /// Turned on in Settings: notifications asked for, and the looking begun
    /// from now (nothing already on the server is announced). Whether they're
    /// allowed.
    func turnOn() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        UserDefaults.standard.set(granted, forKey: Self.enabledKey)
        guard granted else { return false }
        if let client = Self.client { await check(client: client, announcing: false) }
        schedule()
        return true
    }

    func turnOff() {
        UserDefaults.standard.set(false, forKey: Self.enabledKey)
        #if os(iOS)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskID)
        #elseif os(macOS)
        scheduler?.invalidate()
        scheduler = nil
        #endif
    }

    // MARK: When

    /// The next look asked for: on an iPhone, an hour or more from now, as
    /// iOS decides; on a Mac, every hour from now while the app runs.
    func schedule() {
        guard Self.isOn else { return }
        #if os(iOS)
        let request = BGAppRefreshTaskRequest(identifier: Self.taskID)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        try? BGTaskScheduler.shared.submit(request)
        #elseif os(macOS)
        guard scheduler == nil else { return }
        let hourly = NSBackgroundActivityScheduler(identifier: Self.taskID)
        hourly.repeats = true
        hourly.interval = 60 * 60
        hourly.tolerance = 10 * 60
        hourly.qualityOfService = .utility
        hourly.schedule { done in
            Task { @MainActor in
                if let client = Self.client { await NewEpisodes.shared.check(client: client) }
                done(.finished)
            }
        }
        scheduler = hourly
        #endif
    }

    /// iOS's background refresh: a look, and the next one asked for.
    func backgroundCheck() async {
        schedule()
        guard let client = Self.client else { return }
        await check(client: client)
    }

    /// The app's own connection, or, woken in the background before the app
    /// has made one, the session it keeps for its widgets.
    private static var client: MediaBrowserClient? {
        (AppState.current?.client as? MediaBrowserClient) ?? SharedSession.current()?.client
    }

    // MARK: Looking

    /// Episodes the server has added since the last look, of shows this
    /// account watches, each show's told in one notification. The first look
    /// for an account only notes where things stand.
    func check(client: MediaBrowserClient, announcing: Bool = true) async {
        guard Self.isOn, let uid = client.userId else { return }
        let key = "goosetv.newEpisodes.\(client.baseURL.absoluteString)|\(uid)"
        let defaults = UserDefaults.standard
        guard let recent = try? await client.recentlyAddedEpisodes(limit: 80) else { return }
        // Measured by the server's clock, not this device's: the newest date
        // the server gave is where the next look starts.
        let added = recent.compactMap { episode in episode.dateCreated.flatMap(ServerDates.parse).map { (episode, $0) } }
        let newest = added.map(\.1).max()
        guard announcing, let since = defaults.object(forKey: key + ".since") as? Date else {
            defaults.set(newest ?? Date(), forKey: key + ".since")
            return
        }
        let fresh = added.filter { $0.1 > since && $0.0.userData?.played != true }.map(\.0)
        // Moved on only once what's new has been looked at: if the shows
        // followed can't be read now, the next look starts from here again.
        func moveOn() { if let newest, newest > since { defaults.set(newest, forKey: key + ".since") } }
        guard !fresh.isEmpty else { return moveOn() }
        guard let followed = try? await client.followedSeriesIds() else { return }
        moveOn()
        var told = defaults.stringArray(forKey: key + ".told") ?? []
        let mine = fresh.filter { episode in episode.seriesId.map(followed.contains) == true && !told.contains(episode.id) }
        guard !mine.isEmpty else { return }
        for (_, episodes) in Dictionary(grouping: mine, by: { $0.seriesId ?? "" }) {
            await announce(episodes.sorted { ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0) < ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0) },
                           client: client)
        }
        told = Array((told + mine.map(\.id)).suffix(300))
        defaults.set(told, forKey: key + ".told")
    }

    /// One show's new episodes: "New episode of Bluey" with the episode, or
    /// "3 new episodes of Bluey" with them listed; opens the first.
    private func announce(_ episodes: [BaseItem], client: MediaBrowserClient) async {
        guard let first = episodes.first else { return }
        let show = first.seriesName ?? first.displayTitle
        let content = UNMutableNotificationContent()
        content.title = episodes.count == 1
            ? String(localized: "New episode of \(show)", comment: "Notification title: a new episode is on the server; the placeholder is the show")
            : String(localized: "\(episodes.count) new episodes of \(show)", comment: "Notification title: new episodes are on the server; the placeholders are how many and the show")
        content.body = episodes.prefix(3).map { episode in
            [episode.episodeLabel, episode.name].compactMap { $0 }.joined(separator: " · ")
        }.joined(separator: "\n")
        content.sound = .default
        content.threadIdentifier = "new-episodes"
        content.userInfo = ["itemId": first.id]
        // The episode's picture, which the system takes from a file of its own.
        if let url = client.imageURL(for: first, maxWidth: 600),
           let (data, response) = try? await URLSession.shared.data(from: url),
           (response as? HTTPURLResponse)?.statusCode == 200 {
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("episode-\(first.id).jpg")
            if (try? data.write(to: file)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "picture", url: file) {
                content.attachments = [attachment]
            }
        }
        #if os(macOS) && DEBUG
        MacDebugSnapshots.log("announce: \(content.title) | \(content.body.replacingOccurrences(of: "\n", with: " / ")) | picture \(!content.attachments.isEmpty)")
        #endif
        let request = UNNotificationRequest(identifier: "episode-\(first.seriesId ?? first.id)-\(first.id)", content: content, trigger: nil)
        try? await UNUserNotificationCenter.current().add(request)
    }
}
#endif
