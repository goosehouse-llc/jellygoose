import Foundation
import os

/// The playback reports still in flight.
///
/// Closing the player and reloading the page it came from are simultaneous: the
/// stop report goes one way while the screen asks the server for the item again.
/// The read usually wins, and the item comes back with the position it had before
/// the film was watched — so a half-watched movie offered "Play" instead of
/// "Resume" until the page was opened again. Screens reloading after playback wait
/// here first.
///
/// Locked rather than actor-isolated so a player tearing down can register its
/// report in the same turn it starts it: a hop to the main actor lands after the
/// screen behind has already drained the queue, which is the race this exists to
/// close. The lock is only ever held for one set operation, never across an
/// await.
final class PlaybackReports: Sendable {
    static let shared = PlaybackReports()

    private let outstanding = OSAllocatedUnfairLock(initialState: Set<UUID>())

    /// Counts a report as in flight until it finishes on its own.
    func track(_ report: Task<Void, Never>) {
        let id = UUID()
        outstanding.withLock { _ = $0.insert(id) }
        Task {
            await report.value
            self.outstanding.withLock { _ = $0.remove(id) }
        }
    }

    private var isSettled: Bool {
        outstanding.withLock { $0.isEmpty }
    }

    /// Waits for those reports, but not forever: a server that has stopped
    /// answering shouldn't hold up the screen behind it. Whatever is still in
    /// flight at the deadline is abandoned rather than waited on — its result
    /// would arrive too late to matter either way.
    func settle(timeout: Duration = .seconds(3)) async {
        let deadline = ContinuousClock().now + timeout
        while !isSettled, ContinuousClock().now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        outstanding.withLock { $0.removeAll() }
    }
}

/// One player's reports, sent in the order they were made. Each was a task of
/// its own and nothing ordered them, so a Stopped filed straight after a
/// Playing (a stream that failed at once, a track changed as the film began)
/// could reach the server first, and it kept showing the film as playing.
///
/// Each report waits for the one before it, but only for so long: one caught
/// on a server that has stopped answering shouldn't hold back the rest.
final class PlaybackReportQueue {
    private let lock = NSLock()
    private var last: Task<Void, Never>?

    /// Sends `report` once the one before it has gone; the task, for tracking.
    @discardableResult
    func send(_ report: @escaping () async -> Void) -> Task<Void, Never> {
        lock.withLock {
            let previous = last
            let task = Task {
                if let previous { _ = await withinDeadline(3) { await previous.value; return true } }
                await report()
            }
            last = task
            return task
        }
    }
}
