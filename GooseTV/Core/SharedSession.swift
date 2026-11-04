import Foundation

/// The signed-in session, in the one place both the app and the Top Shelf
/// extension can reach.
///
/// The extension is its own process with its own container, so the app's
/// UserDefaults is invisible to it and so is the app's default keychain group.
/// Both targets instead carry the access group below — which is the app's own
/// group, where a token saved before any of this already lives, so no stored
/// token has to move. With this the shelf can ask the server what to watch next
/// without a sign-in of its own.
///
/// The server address and user id are not secrets, but they travel with the
/// token rather than in an app group: one shared mechanism to get right instead
/// of two, and one fewer capability to provision.
enum SharedSession {
    /// $(AppIdentifierPrefix) resolved: the team ID, fixed for this app, and the
    /// same string the entitlements of both targets name.
    static let accessGroup = "579BSQT6J4.com.goosehouse.jellygoose"

    private static let query = Keychain.query(service: "app.jellygoose.session", account: "current",
                                              group: accessGroup)

    private struct Stored: Codable {
        let serverURL: String
        let flavor: String
        let userId: String
        /// Absent in items written before the shelf could be switched off, which
        /// is the same as on.
        var showsOnHomeScreen: Bool?
        /// Next Up episodes the viewer removed; absent means none.
        var hiddenNextUp: [String]?
    }

    /// The session as the extension sees it.
    struct Current {
        let client: MediaBrowserClient
        /// Whether the viewer wants the shelf at all. The app keeps the
        /// preference itself; this is the extension's copy of it.
        let showsOnHomeScreen: Bool
        /// The extension's copy of the episodes taken off Next Up, which the
        /// shelf leaves out too.
        let hiddenNextUp: Set<String>
    }

    /// The signed-in session, or nil when nobody is signed in. The shelf has
    /// no way to ask for credentials, so it simply shows nothing.
    static func current() -> Current? {
        guard let stored = stored(),
              let url = URL(string: stored.serverURL),
              let token = TokenStore.token() else { return nil }
        let client = MediaBrowserClient(baseURL: url,
                                        flavor: ServerFlavor(rawValue: stored.flavor) ?? .jellyfin,
                                        token: token, userId: stored.userId)
        return Current(client: client, showsOnHomeScreen: stored.showsOnHomeScreen ?? true,
                       hiddenNextUp: Set(stored.hiddenNextUp ?? []))
    }

    /// Records the session for the extension. Called wherever the app learns
    /// these facts, including on restore, so an install that signed in before
    /// the shelf existed fills it in without signing in again.
    static func save(baseURL: URL, flavor: ServerFlavor, userId: String,
                     showsOnHomeScreen: Bool, hiddenNextUp: [String]) {
        write(Stored(serverURL: baseURL.absoluteString, flavor: flavor.rawValue,
                     userId: userId, showsOnHomeScreen: showsOnHomeScreen,
                     hiddenNextUp: hiddenNextUp))
    }

    /// Turns the shelf on or off without disturbing the session around it.
    /// Does nothing when nobody is signed in: there is no shelf to turn off,
    /// and the next sign-in brings the app's own preference with it.
    static func setShowsOnHomeScreen(_ on: Bool) {
        update { $0.showsOnHomeScreen = on }
    }

    static func setHiddenNextUp(_ ids: [String]) {
        update { $0.hiddenNextUp = ids }
    }

    private static func update(_ change: (inout Stored) -> Void) {
        guard var stored = stored() else { return }
        change(&stored)
        write(stored)
    }

    private static func write(_ stored: Stored) {
        guard let data = try? JSONEncoder().encode(stored) else { return }
        Keychain.write(data, query)
    }

    static func clear() {
        Keychain.delete(query)
    }

    /// On an Apple TV: the session an earlier version left in the keychain
    /// the TV's people share, from before the app ran as each of them (see
    /// `TokenStore.takeEarlier`). Taken once.
    static func takeEarlier() -> (url: URL, flavor: ServerFlavor, userId: String, showsOnHomeScreen: Bool?, hiddenNextUp: [String]?)? {
        guard Keychain.hasHousehold else { return nil }
        let earlier = Keychain.query(service: "app.jellygoose.session", account: "current", group: accessGroup, household: true)
        guard let stored = Keychain.read(earlier).flatMap({ try? JSONDecoder().decode(Stored.self, from: $0) }),
              let url = URL(string: stored.serverURL) else { return nil }
        Keychain.delete(earlier)
        return (url, ServerFlavor(rawValue: stored.flavor) ?? .jellyfin, stored.userId, stored.showsOnHomeScreen, stored.hiddenNextUp)
    }

    private static func stored() -> Stored? {
        Keychain.read(query).flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
    }
}
