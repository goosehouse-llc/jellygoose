import Foundation

/// What a film's page works out while the viewer reads it: the item as it is
/// now, its stream, and its skip markers. Pressing Play then goes straight to
/// starting the stream instead of asking the server three things first.
/// Asking starts nothing on the server; only fetching the stream does, and a
/// preparation nobody plays is simply dropped.
@MainActor
final class PlaybackPrep {
    static let shared = PlaybackPrep()

    struct Prepared {
        let item: BaseItem
        let context: PlaybackContext
        let segments: [SkipSegment]
    }

    private struct Entry {
        let task: Task<Prepared?, Never>
        let at: Date
    }

    private var entries: [String: Entry] = [:]
    /// Long enough to read a page, short enough that a resume point moved on
    /// another device isn't used.
    private static let freshFor: TimeInterval = 90

    private static func key(_ id: String, _ mediaSourceId: String?) -> String { "\(id)|\(mediaSourceId ?? "")" }

    /// Starts preparing, unless a fresh preparation is already on its way.
    func prepare(_ target: BaseItem, mediaSourceId: String?, client: any MediaServer) {
        let key = Self.key(target.id, mediaSourceId)
        if let entry = entries[key], Date().timeIntervalSince(entry.at) < Self.freshFor { return }
        entries = entries.filter { Date().timeIntervalSince($0.value.at) < Self.freshFor }
        let id = target.id
        let task = Task<Prepared?, Never> {
            guard let item = try? await client.item(id: id) else { return nil }
            // Capped as the player's own start caps it: skip buttons aren't
            // worth holding the picture for, and a server without the plugin
            // can take three slow answers to say it has nothing.
            let marked = Task { await giveUp(after: 4) { await client.skipSegments(for: id) } ?? [] }
            guard let context = try? await client.playbackContext(for: item, startTicks: item.resumeTicks,
                                                                  audioIndex: nil, subtitleIndex: nil,
                                                                  mediaSourceId: mediaSourceId)
            else { marked.cancel(); return nil }
            return Prepared(item: item, context: context, segments: await marked.value)
        }
        entries[key] = Entry(task: task, at: Date())
    }

    /// The preparation for this item, if there's a fresh one, used once.
    func take(_ id: String, mediaSourceId: String?) async -> Prepared? {
        let key = Self.key(id, mediaSourceId)
        guard let entry = entries.removeValue(forKey: key),
              Date().timeIntervalSince(entry.at) < Self.freshFor else { return nil }
        return await entry.task.value
    }

    /// Forgets everything: something changed (watched, a track picked) that
    /// a preparation made before it wouldn't know about.
    func forget() { entries.removeAll() }
}

/// What `work` answers, or nil if it hasn't answered in `seconds`: past that
/// it's cancelled, which a request to the server answers at once. For work
/// that uses the server's client, which `withinDeadline` can't be handed
/// (its work has to be Sendable, and the client isn't).
func giveUp<T: Sendable>(after seconds: Double, _ work: @escaping () async -> T?) async -> T? {
    let task = Task { await work() }
    let cutoff = Task {
        try? await Task.sleep(for: .seconds(seconds))
        task.cancel()
    }
    defer { cutoff.cancel() }
    return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
}
