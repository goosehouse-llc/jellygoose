import Foundation

/// When to ask for a rating: after some real watching, not in the first days,
/// at most once a version and months apart, and never again once declined.
///
/// The iPad asks with Apple's own prompt, which rations itself further. The
/// Apple TV has no such prompt, so it shows a card of its own with a code to
/// scan and rate on a phone; `tvCardEnabled` turns that card off should App
/// Review hold it against guideline 5.6.1.
@MainActor
enum ReviewPrompt {
    static let tvCardEnabled = true
    /// The App Store's write-a-review page for the app.
    static let reviewURL = URL(string: "https://apps.apple.com/app/id6814667375?action=write-review")!

    private static let defaults = UserDefaults.standard
    private static let playsNeeded = 5
    private static let daysInstalled: TimeInterval = 3
    private static let daysBetween: TimeInterval = 120
    /// A play counts once it has been open this long, which a trailer or a
    /// film abandoned in its first minutes doesn't reach.
    private static let playLength: TimeInterval = 10 * 60

    private enum Key {
        static let firstLaunch = "review.firstLaunch"
        static let plays = "review.plays"
        static let askedVersion = "review.askedVersion"
        static let askedAt = "review.askedAt"
        static let never = "review.never"
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    static func noteLaunch() {
        if defaults.object(forKey: Key.firstLaunch) == nil { defaults.set(Date(), forKey: Key.firstLaunch) }
    }

    static func notePlay(lasting seconds: TimeInterval) {
        guard seconds >= playLength else { return }
        defaults.set(defaults.integer(forKey: Key.plays) + 1, forKey: Key.plays)
    }

    static var isDue: Bool {
        #if os(tvOS)
        guard tvCardEnabled else { return false }
        #endif
        guard !defaults.bool(forKey: Key.never),
              defaults.integer(forKey: Key.plays) >= playsNeeded,
              let first = defaults.object(forKey: Key.firstLaunch) as? Date,
              Date().timeIntervalSince(first) >= daysInstalled * 86_400,
              defaults.string(forKey: Key.askedVersion) != version else { return false }
        if let last = defaults.object(forKey: Key.askedAt) as? Date,
           Date().timeIntervalSince(last) < daysBetween * 86_400 { return false }
        return true
    }

    static func asked() {
        defaults.set(version, forKey: Key.askedVersion)
        defaults.set(Date(), forKey: Key.askedAt)
    }

    static func neverAgain() {
        asked()
        defaults.set(true, forKey: Key.never)
    }
}
