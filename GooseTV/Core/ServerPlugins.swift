import Foundation

/// A plugin installed on the server (Jellyfin's /Plugins).
struct ServerPlugin: Decodable, Hashable {
    let name: String
    let version: String
    let id: String
    let description: String?
    /// Active, Disabled, Restart, Deleted, Superceded, Malfunctioned or NotSupported.
    let status: String?
    /// False for the ones the server comes with.
    let canUninstall: Bool?

    var isOn: Bool { status != "Disabled" }
    var removable: Bool { canUninstall == true }
    var key: String { PluginKey.of(id) }
}

/// A plugin a repository the server uses offers (Jellyfin's /Packages).
struct PluginPackage: Decodable, Hashable {
    let name: String
    let guid: String
    let description: String?
    let overview: String?
    let owner: String?
    let category: String?
    let imageUrl: String?
    let versions: [PluginRelease]

    var key: String { PluginKey.of(guid) }
    var image: URL? { imageUrl.flatMap(URL.init(string:)) }

    /// The newest release the server can run: one built for this server's
    /// version or an earlier one.
    func newest(forServer server: String) -> PluginRelease? {
        versions
            .filter { PluginVersion($0.targetAbi ?? "0") <= PluginVersion(server) }
            .max { PluginVersion($0.version) < PluginVersion($1.version) }
    }

    /// Its kind, as the catalog files it.
    var categoryLabel: String {
        switch category {
        case "MoviesAndShows": String(localized: "Movies and Shows", comment: "Plugin catalog heading: plugins for films and shows")
        case "Music": String(localized: "Music", comment: "Eyebrow above a music library's name")
        case "Books": String(localized: "Books", comment: "Plugin catalog heading: plugins for books")
        case "Anime": String(localized: "Anime", comment: "Plugin catalog heading: plugins for anime")
        case "LiveTV": String(localized: "Live TV", comment: "Menu section: the server's television channels")
        case "Subtitles": String(localized: "Subtitles")
        case "Administration": String(localized: "Administration", comment: "Plugin catalog heading: plugins for running the server (sign-in, backups)")
        case "General", nil: String(localized: "General", comment: "Plugin catalog heading: plugins of no particular kind")
        case let other?: other
        }
    }
}

struct PluginRelease: Decodable, Hashable {
    let version: String
    let changelog: String?
    let targetAbi: String?
    let repositoryName: String?
    let repositoryUrl: String?
}

/// The server's version and whether it's waiting to restart, which installing,
/// updating or removing a plugin leaves it doing.
struct ServerRestartState: Hashable {
    let version: String
    let pendingRestart: Bool
    let canRestart: Bool
}

/// One entry of a list that may not read: the catalog merges repositories
/// anyone can publish, and one odd entry wasn't to lose the rest.
struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// The same plugin, installed or in a catalog: Jellyfin writes its id with
/// dashes in one place and without in the other.
enum PluginKey {
    static func of(_ id: String) -> String {
        id.replacingOccurrences(of: "-", with: "").lowercased()
    }
}

/// "10.11.0.0" compared part by part, a missing part counting as 0.
struct PluginVersion: Comparable {
    let parts: [Int]

    init(_ text: String) {
        parts = text.split(separator: ".").map { Int($0) ?? 0 }
    }

    static func < (a: PluginVersion, b: PluginVersion) -> Bool {
        for index in 0..<max(a.parts.count, b.parts.count) {
            let x = index < a.parts.count ? a.parts[index] : 0
            let y = index < b.parts.count ? b.parts[index] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: PluginVersion, b: PluginVersion) -> Bool { !(a < b) && !(b < a) }
}

/// A plugin as the Plugins page shows it: installed, offered, or both.
struct PluginEntry: Hashable, Identifiable {
    var installed: ServerPlugin?
    var package: PluginPackage?
    /// The server's version, for which release it can run.
    var serverVersion: String
    /// Turned on or off here and waiting for the server's restart: the
    /// server says only "Restart" until then, not which.
    var askedOn: Bool? = nil

    var isOn: Bool { askedOn ?? installed?.isOn ?? false }

    var id: String { installed?.key ?? package?.key ?? "" }
    var name: String { installed?.name ?? package?.name ?? "" }
    var image: URL? { package?.image }

    /// The newest release the server can run, if it's newer than what's installed
    /// (or anything, when it isn't installed).
    var available: PluginRelease? {
        guard let newest = package?.newest(forServer: serverVersion) else { return nil }
        guard let installed else { return newest }
        return PluginVersion(newest.version) > PluginVersion(installed.version) ? newest : nil
    }

    /// The catalog has it, but every release needs a newer server.
    var needsNewerServer: Bool {
        guard let package, installed == nil else { return false }
        return !package.versions.isEmpty && package.newest(forServer: serverVersion) == nil
    }
}
