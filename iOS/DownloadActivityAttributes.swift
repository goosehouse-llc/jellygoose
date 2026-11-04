import ActivityKit
import Foundation

/// Downloads coming down, on the Lock Screen and in the Dynamic Island.
/// Shared by the app, which starts and updates it, and the widgets, which
/// draw it.
struct DownloadActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// The one coming down now: "Pond Life", "The Office · S2 · E3".
        var title: String
        /// How many are still coming, that one included.
        var remaining: Int
        /// How far that one has got, 0 to 1.
        var fraction: Double
        /// Held for Wi-Fi (the setting), with only mobile data about.
        var waitingForWiFi: Bool
        /// All of them down: shown a moment before it goes.
        var finished: Bool
    }
}
