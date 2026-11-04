#if !os(tvOS)
import Foundation

/// Shows kept downloaded: for each, the next few episodes not watched yet
/// are on the device, downloaded as they come up, and the ones it brought
/// down are deleted once they've been watched. A download made by hand is
/// never deleted by this.
@MainActor
final class SmartDownloads: ObservableObject {
    static let shared = SmartDownloads()

    /// How many episodes to keep of each show, by the show's id.
    @Published private(set) var kept: [String: Int] = [:]
    /// The shows' names, for the Downloads screen to list them by.
    @Published private(set) var names: [String: String] = [:]

    /// The episodes this downloaded, and each one's show: the only ones it
    /// deletes.
    private var made: [String: String] = [:]
    /// Whose shows these are: the server's address and the account's id.
    private var account: String?
    private var running = false
    /// Asked for while running: once more, when it's done.
    private var again = false

    /// What a show can be kept at.
    static let choices = [1, 3, 5, 10]

    private struct Saved: Codable {
        var kept: [String: Int] = [:]
        var names: [String: String] = [:]
        var made: [String: String] = [:]
    }

    private static let key = "goosetv.smartDownloads"

    /// The account signed in: its shows, not another's.
    func use(_ client: MediaBrowserClient?) {
        let next = client.flatMap { client in client.userId.map { client.baseURL.absoluteString + "|" + $0 } }
        guard next != account else { return }
        account = next
        let saved = next.flatMap { Self.all()[$0] } ?? Saved()
        kept = saved.kept
        names = saved.names
        made = saved.made
    }

    func keeps(_ seriesId: String) -> Int? { kept[seriesId] }

    /// Keeps `count` episodes of the show downloaded, or (nil) stops. What it
    /// had brought down stays, as the viewer's own downloads now.
    func keep(seriesId: String, name: String, count: Int?, client: MediaBrowserClient) {
        use(client)
        if let count {
            kept[seriesId] = count
            names[seriesId] = name
        } else {
            kept[seriesId] = nil
            names[seriesId] = nil
            made = made.filter { $0.value != seriesId }
        }
        save()
        Task { await refresh(client: client) }
    }

    /// Brings each show's downloads up to date: the next episodes down, the
    /// watched ones it made gone. Run as the app comes forward, as the
    /// server is reached, and after anything's been watched.
    func refresh(client: MediaBrowserClient) async {
        use(client)
        guard !kept.isEmpty else { return }
        guard !running else { again = true; return }
        running = true
        defer { running = false }
        let downloads = Downloads.shared
        for (seriesId, count) in kept {
            let wanted = await client.episodesToWatch(seriesId: seriesId, limit: count)
            let wantedIds = Set(wanted.map(\.id))
            // Its own, watched now and not among the next: deleted.
            let mine = made.filter { $0.value == seriesId }.map(\.key)
            if !mine.isEmpty, let states = try? await client.items(ids: mine) {
                let present = Set(states.map(\.id))
                for episode in states where episode.userData?.played == true && !wantedIds.contains(episode.id) {
                    guard downloads.record(episode.id)?.state != .downloading else { continue }
                    downloads.removeFinished(episode.id)
                    made[episode.id] = nil
                }
                // Gone from the server, or taken off the device by hand: not its to keep track of.
                for id in mine where !present.contains(id) || downloads.record(id) == nil {
                    if !wantedIds.contains(id) { made[id] = nil }
                }
            }
            for episode in wanted where downloads.record(episode.id) == nil {
                // Stops at the first that can't start (no space, no server).
                guard await downloads.download(episode, client: client) == nil else { break }
                made[episode.id] = seriesId
            }
        }
        save()
        if again {
            again = false
            Task { await refresh(client: client) }
        }
    }

    private func save() {
        guard let account else { return }
        var all = Self.all()
        all[account] = Saved(kept: kept, names: names, made: made)
        if let data = try? JSONEncoder().encode(all) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    private static func all() -> [String: Saved] {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode([String: Saved].self, from: $0) } ?? [:]
    }

    /// "Next 3 Episodes".
    static func label(_ count: Int) -> String {
        count == 1 ? String(localized: "Next Episode", comment: "Keep Downloaded: the one episode to watch next")
                   : String(localized: "Next \(count) Episodes", comment: "Keep Downloaded: how many episodes to watch next are kept on the device")
    }
}
#endif
