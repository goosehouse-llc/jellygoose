import SwiftUI

/// Stops whatever is playing after a while, or when the film, episode or
/// programme on screen ends: for falling asleep in front of the television.
/// One for the whole app, as one thing plays at a time; set from the film
/// player's row or the list a press up opens over a channel, and kept from
/// one channel to the next and from one film to another. When it runs out,
/// the screens playing are told to stop (a channel lets its tuner go), and
/// the television is left to sleep as it does with nothing playing.
@MainActor
final class SleepTimer: ObservableObject {
    static let shared = SleepTimer()

    /// When it runs out, where it's set to a length of time.
    @Published private(set) var ends: Date?
    /// Set to stop when what's playing ends: the film or the episode (the
    /// next episode isn't begun), or for a channel the programme on it,
    /// which is a time.
    @Published private(set) var atEnd = false

    var isSet: Bool { ends != nil || atEnd }

    /// The lengths offered, in minutes.
    static let lengths = [15, 30, 45, 60, 90]

    private var running: Task<Void, Never>?
    /// What stops each screen that's playing, by the screen.
    private var stoppers: [UUID: () -> Void] = [:]

    func set(minutes: Int) {
        set(until: Date().addingTimeInterval(TimeInterval(minutes) * Self.minute))
    }

    /// Dev convenience: GOOSETV_SLEEP_SECONDS=1 makes a minute a second, to
    /// see it run out.
    private static let minute = Double(ProcessInfo.processInfo.environment["GOOSETV_SLEEP_SECONDS"] ?? "") ?? 60

    /// To run out at a time: a programme's end.
    func set(until moment: Date) {
        atEnd = false
        ends = moment
        running?.cancel()
        running = Task { [weak self] in
            let wait = moment.timeIntervalSinceNow
            if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
            guard !Task.isCancelled else { return }
            self?.runOut()
        }
    }

    /// To stop when the film or episode playing ends.
    func setAtEnd() {
        running?.cancel()
        ends = nil
        atEnd = true
    }

    func cancel() {
        running?.cancel()
        running = nil
        ends = nil
        atEnd = false
    }

    /// Asked by the film player as a film ends: whether the timer was
    /// waiting for that, in which case it's spent and nothing more plays.
    func endsWithThis() -> Bool {
        guard atEnd else { return false }
        cancel()
        return true
    }

    /// A screen that plays something says how it's stopped, for as long as
    /// it's up. Returns what it's known by, to be let go of with `forget`.
    func register(_ stop: @escaping () -> Void) -> UUID {
        let id = UUID()
        stoppers[id] = stop
        return id
    }

    func forget(_ id: UUID?) {
        if let id { stoppers[id] = nil }
    }

    private func runOut() {
        let all = Array(stoppers.values)
        cancel()
        all.forEach { $0() }
    }

    // MARK: What's said of it

    static var title: String {
        String(localized: "Sleep Timer", comment: "Player menu: stops playback after a while, or when what's playing ends")
    }

    static var whenThisEnds: String {
        String(localized: "When This Ends", comment: "Sleep timer choice: stop when the film, episode or programme playing ends")
    }

    /// "15 minutes", "1 hour, 30 minutes", as the device says lengths of time.
    static func length(_ minutes: Int) -> String {
        Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    /// What the menu's button says it's set to: Off, the time left, or that
    /// it waits for the end.
    func summary(at now: Date = Date()) -> String {
        if atEnd { return Self.whenThisEnds }
        guard let ends else { return String(localized: "Off", comment: "Subtitles turned off") }
        let minutes = max((ends.timeIntervalSince(now) / 60).rounded(.up), 1)
        let amount = Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .narrow))
        return String(localized: "\(amount) left", comment: "How much of a television programme is still to run; the placeholder is a length of time like 1h 33m")
    }
}

/// Over the picture in the last minute before the sleep timer stops it:
/// how long is left, so it can be put off from the menu in time.
struct SleepCountdown: View {
    @ObservedObject var timer = SleepTimer.shared

    var body: some View {
        if let ends = timer.ends {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = ends.timeIntervalSince(context.date)
                if left <= 60, left > 0 {
                    let clock = Duration.seconds(left.rounded(.up)).formatted(.time(pattern: .minuteSecond))
                    HStack(spacing: 10) {
                        Image(systemName: "moon.zzz.fill")
                        Text(String(localized: "Stopping in \(clock)", comment: "Over the picture in the sleep timer's last minute; the placeholder is a time like 0:42"))
                            .monospacedDigit()
                    }
                    .font(.app(20, .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.65), in: Capsule())
                    .padding(.top, CGFloat(44).scaled)
                    .padding(.trailing, CGFloat(48).scaled)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
        }
    }
}
