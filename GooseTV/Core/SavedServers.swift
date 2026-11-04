import Foundation

/// The servers signed in to before, so the next one doesn't have to be typed
/// out on a remote control.
///
/// Addresses only — no tokens. Signing in still happens per server, which keeps
/// one stored credential and one signed-in session, the way the rest of the app
/// assumes. What this removes is retyping an IP address with the on-screen
/// keyboard, which is the part that actually hurts.
struct SavedServer: Codable, Identifiable, Hashable {
    /// The address, which is also what makes one server different from another.
    let url: String
    var name: String?
    var flavor: ServerFlavor

    var id: String { url }
}

/// On an Apple TV, kept where everyone on the TV can read them, as the
/// accounts are (see `SavedAccounts`): someone new to the app has their
/// household's server to hand.
enum SavedServers {
    private static let key = "goosetv.savedServers"
    /// This person's own list has been added to the household's.
    private static let sharedKey = "goosetv.savedServersShared"
    private static let limit = 8
    private static let roster = Keychain.query(service: "app.jellygoose.household", account: "servers", household: true)

    static func all() -> [SavedServer] {
        guard Keychain.hasHousehold else { return own() }
        let shared = Keychain.read(roster).flatMap { try? JSONDecoder().decode([SavedServer].self, from: $0) } ?? []
        // This person's own, as an earlier version kept them, added the once.
        guard !UserDefaults.standard.bool(forKey: sharedKey) else { return shared }
        UserDefaults.standard.set(true, forKey: sharedKey)
        let mine = own().filter { server in !shared.contains { $0.id == server.id } }
        guard !mine.isEmpty else { return shared }
        write(shared + mine)
        return shared + mine
    }

    /// Most recently signed in to first, and never the same address twice.
    static func remember(url: URL, name: String?, flavor: ServerFlavor) {
        var servers = all().filter { $0.url != url.absoluteString }
        servers.insert(SavedServer(url: url.absoluteString, name: name, flavor: flavor), at: 0)
        write(Array(servers.prefix(limit)))
    }

    static func forget(_ server: SavedServer) {
        write(all().filter { $0.id != server.id })
    }

    private static func own() -> [SavedServer] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let servers = try? JSONDecoder().decode([SavedServer].self, from: data) else { return [] }
        return servers
    }

    private static func write(_ servers: [SavedServer]) {
        guard let data = try? JSONEncoder().encode(servers) else { return }
        if Keychain.hasHousehold { Keychain.write(data, roster) } else { UserDefaults.standard.set(data, forKey: key) }
    }
}
