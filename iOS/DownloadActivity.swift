import ActivityKit
import Combine
import Foundation

/// Keeps the downloads' Live Activity in step with them: begun when one
/// starts coming down, told as they get on (a few times a minute at most),
/// and ended a moment after the last is in.
///
/// The system only lets the app start one while it's on screen, and the app
/// only hears of progress while it runs: put away, the activity shows where
/// things had got to until the app is woken as they finish.
@MainActor
final class DownloadActivity {
    static let shared = DownloadActivity()

    private var activity: Activity<DownloadActivityAttributes>?
    private var watching: AnyCancellable?
    private var sent: DownloadActivityAttributes.ContentState?
    private var sentAt = Date.distantPast

    func start() {
        // One left from before the app was stopped: carried on with, not doubled.
        activity = Activity<DownloadActivityAttributes>.activities.first
        watching = Downloads.shared.$records.sink { [weak self] records in
            // After the change is in place: the publisher speaks before it.
            Task { @MainActor in self?.follow(records) }
        }
    }

    private func follow(_ records: [String: DownloadRecord]) {
        let coming = records.values.filter { $0.state == .downloading }.sorted { $0.addedAt < $1.addedAt }
        guard let current = coming.first(where: { $0.bytesWritten > 0 && $0.bytesWritten < max($0.bytesExpected, 1) }) ?? coming.first else {
            finish()
            return
        }
        let downloads = Downloads.shared
        let state = DownloadActivityAttributes.ContentState(
            title: Self.title(downloads.item(current.id)),
            remaining: coming.count,
            fraction: downloads.progress(current.id) ?? 0,
            waitingForWiFi: downloads.waitingForWiFi(current.id),
            finished: false)
        // Every few percent, or a change of what's coming, or now and then.
        if let sent, sent.title == state.title, sent.remaining == state.remaining, sent.waitingForWiFi == state.waitingForWiFi,
           abs(sent.fraction - state.fraction) < 0.03, Date().timeIntervalSince(sentAt) < 20 {
            return
        }
        send(state)
    }

    private func send(_ state: DownloadActivityAttributes.ContentState) {
        sent = state
        sentAt = Date()
        // Grey (stale) on the Lock Screen if nothing more is heard for a while.
        let content = ActivityContent(state: state, staleDate: Date().addingTimeInterval(15 * 60))
        if let activity, activity.activityState == .active {
            Task { await activity.update(content) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(attributes: DownloadActivityAttributes(), content: content)
        }
    }

    /// Nothing coming down: "Downloaded" for a moment, then gone.
    private func finish() {
        guard let activity else { return }
        self.activity = nil
        let last = sent
        sent = nil
        let state = DownloadActivityAttributes.ContentState(title: last?.title ?? "", remaining: 0, fraction: 1,
                                                            waitingForWiFi: false, finished: true)
        Task {
            await activity.end(ActivityContent(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(8)))
        }
    }

    /// "Gooseflight Alpha", "Goosewatch · S1 · E2".
    private static func title(_ item: BaseItem?) -> String {
        guard let item else { return "" }
        guard item.isEpisode, let show = item.seriesName else { return item.displayTitle }
        return [show, item.episodeLabel].compactMap { $0 }.joined(separator: " · ")
    }
}
