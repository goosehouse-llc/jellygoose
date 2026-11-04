import Foundation

/// An account signed in on this Apple TV. What identifies it is kept in
/// UserDefaults; its token, which is a credential, in the keychain.
struct SavedAccount: Codable, Identifiable, Hashable {
    let serverURL: String
    let userId: String
    var name: String
    var imageTag: String?
    var flavor: ServerFlavor

    var id: String { "\(serverURL)|\(userId)" }
}

/// Everyone signed in on this Apple TV, so a household can switch between
/// accounts the way it switches profiles elsewhere: by picking a face, not by
/// typing a password with a remote. Switching user keeps the account here;
/// signing out forgets it.
///
/// On an Apple TV the app runs as whoever is using the TV, each person with
/// their own settings and keychain, so the list and its tokens are kept in
/// the keychain everyone on the TV shares (`Keychain.hasHousehold`): someone
/// opening the app for the first time picks their face from it. Before that,
/// they were kept in the app's own settings and keychain, and are moved over
/// the first time they're asked for.
enum SavedAccounts {
    private static let key = "goosetv.savedAccounts"
    /// This person's own list has been added to the household's.
    private static let sharedKey = "goosetv.savedAccountsShared"
    private static let service = "app.jellygoose.account-token"
    private static let roster = Keychain.query(service: "app.jellygoose.household", account: "accounts", household: true)

    /// Most recently used first.
    static func all() -> [SavedAccount] {
        guard Keychain.hasHousehold else { return own() }
        let shared = Keychain.read(roster).flatMap { try? JSONDecoder().decode([SavedAccount].self, from: $0) } ?? []
        // This person's own, as an earlier version kept them, added the once.
        guard !UserDefaults.standard.bool(forKey: sharedKey) else { return shared }
        UserDefaults.standard.set(true, forKey: sharedKey)
        let mine = own().filter { account in !shared.contains { $0.id == account.id } }
        guard !mine.isEmpty else { return shared }
        for account in mine {
            if let token = Keychain.read(query(for: account, household: false)) {
                Keychain.write(token, query(for: account))
            }
        }
        write(shared + mine)
        return shared + mine
    }

    static func on(server url: URL) -> [SavedAccount] {
        all().filter { $0.serverURL == url.absoluteString }
    }

    static func remember(_ account: SavedAccount, token: String) {
        let others = all().filter { $0.id != account.id }
        Keychain.write(Data(token.utf8), query(for: account))
        write([account] + others)
    }

    /// Kept too, behind those used more recently: an account found rather
    /// than used.
    static func add(_ account: SavedAccount, token: String) {
        var accounts = all()
        Keychain.write(Data(token.utf8), query(for: account))
        guard let at = accounts.firstIndex(where: { $0.id == account.id }) else { return write(accounts + [account]) }
        // There already, perhaps without a name or a picture (taken up from
        // an earlier version's session): filled in, left in its place.
        guard accounts[at].name.isEmpty || accounts[at].imageTag == nil else { return }
        if accounts[at].name.isEmpty { accounts[at].name = account.name }
        if accounts[at].imageTag == nil { accounts[at].imageTag = account.imageTag }
        write(accounts)
    }

    static func token(for account: SavedAccount) -> String? {
        (Keychain.read(query(for: account)) ?? Keychain.read(query(for: account, household: false)))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    static func forget(_ account: SavedAccount) {
        let others = all().filter { $0.id != account.id }
        Keychain.delete(query(for: account))
        Keychain.delete(query(for: account, household: false))
        write(others)
    }

    static func forget(serverURL: String, userId: String) {
        guard let account = all().first(where: { $0.serverURL == serverURL && $0.userId == userId }) else { return }
        forget(account)
    }

    /// The tokens kept under this name in the keychain shared by everyone on
    /// the TV, by account: where a version from before the TV was shared out
    /// may have left them.
    static func householdTokens() -> [(id: String, token: String)] {
        Keychain.readAll(query(for: nil)).compactMap { item in
            String(data: item.data, encoding: .utf8).map { (item.account, $0) }
        }
    }

    private static func own() -> [SavedAccount] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let accounts = try? JSONDecoder().decode([SavedAccount].self, from: data) else { return [] }
        return accounts
    }

    private static func write(_ accounts: [SavedAccount]) {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        if Keychain.hasHousehold { Keychain.write(data, roster) } else { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func query(for account: SavedAccount?, household: Bool = true) -> [String: Any] {
        Keychain.query(service: service, account: account?.id ?? "", household: household)
    }
}
