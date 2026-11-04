import Foundation

/// Where the server's access token lives.
///
/// It is a long-lived credential: anyone holding it can read the viewer's
/// library, and on an administrator's account reach the library and filesystem
/// endpoints too. UserDefaults keeps it in a plist inside the app container in
/// plain text, so it lives in the keychain instead, reachable only after the
/// device has been unlocked once and never synced off it.
enum TokenStore {
    /// Named explicitly so the Top Shelf extension, whose own default group is a
    /// different one, can read the same item. It is the group the app already
    /// wrote to by default, so tokens saved before this stay where they are.
    /// One signed-in session at a time, so one account.
    private static let query = Keychain.query(service: "app.jellygoose.server-token", account: "current",
                                              group: SharedSession.accessGroup)

    static func token() -> String? {
        Keychain.read(query).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    static func save(_ token: String) -> Bool {
        Keychain.write(Data(token.utf8), query)
    }

    static func clear() {
        Keychain.delete(query)
    }

    /// On an Apple TV: a token an earlier version left in the keychain the
    /// TV's people share, from before the app ran as each of them. Taken
    /// once: whoever takes it is the one who was signed in.
    static func takeEarlier() -> String? {
        guard Keychain.hasHousehold else { return nil }
        let earlier = Keychain.query(service: "app.jellygoose.server-token", account: "current",
                                     group: SharedSession.accessGroup, household: true)
        guard let token = Keychain.read(earlier).flatMap({ String(data: $0, encoding: .utf8) }) else { return nil }
        Keychain.delete(earlier)
        return token
    }
}
