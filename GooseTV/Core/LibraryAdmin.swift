import Foundation

/// A library as the server defines it (Jellyfin calls these virtual folders):
/// a name, a kind, and the folders on the server it's built from.
struct VirtualFolder: Decodable, Identifiable, Hashable {
    let name: String
    let itemId: String?
    let collectionType: String?
    let locations: [String]?

    var id: String { itemId ?? name }
    var folders: [String] { locations ?? [] }

    var kind: LibraryKind { LibraryKind(rawValue: collectionType ?? "") ?? .mixed }

    /// Its kind as shown: the ones this app makes, and the others the
    /// server has (which all read "Mixed" before).
    var kindLabel: String {
        switch collectionType {
        case "music": String(localized: "Music", comment: "Eyebrow above a music library's name")
        case "books": String(localized: "Audiobooks", comment: "Eyebrow above a library of books, and Home's row of them")
        case "boxsets": String(localized: "Collections")
        case "playlists": String(localized: "Playlists", comment: "Music library: the server's playlists of songs")
        case "livetv": String(localized: "Live TV", comment: "Menu section: the server's television channels")
        default: kind.label
        }
    }

    /// What its items are counted by: what it holds. Counted by films and
    /// shows, a library of music or books came to none.
    var countedTypes: String {
        switch collectionType {
        case "music": "MusicAlbum"
        case "books": "AudioBook"
        case "boxsets": "BoxSet"
        case "playlists": "Playlist"
        default: "Movie,Series,Episode,Video,MusicVideo,Recording"
        }
    }
}

/// The library kinds GooseTV can create. Jellyfin has more (music, books, photos),
/// but this app only browses video, so it offers the ones it can show.
enum LibraryKind: String, CaseIterable, Identifiable {
    case movies, tvshows, homevideos, musicvideos, mixed

    var id: String { rawValue }

    /// What the server wants; a mixed library is sent without a type.
    var collectionType: String? { self == .mixed ? nil : rawValue }

    var label: String {
        switch self {
        case .movies: return String(localized: "Movies", comment: "Library type")
        case .tvshows: return String(localized: "TV Shows", comment: "Library type")
        case .homevideos: return String(localized: "Home Videos", comment: "Library type")
        case .musicvideos: return String(localized: "Music Videos", comment: "Library type")
        case .mixed: return String(localized: "Mixed", comment: "Library type: movies and shows together")
        }
    }

    var icon: String {
        switch self {
        case .movies: return "film"
        case .tvshows: return "play.tv"
        case .homevideos: return "video"
        case .musicvideos: return "music.note.tv"
        case .mixed: return "rectangle.stack"
        }
    }
}

/// One of the server's background jobs, used to show what a scan is doing.
struct ServerTask: Decodable, Identifiable, Hashable {
    let name: String?
    let key: String?
    let state: String?
    let currentProgressPercentage: Double?

    var id: String { key ?? name ?? UUID().uuidString }
    var isRunning: Bool { state == "Running" || state == "Cancelling" }
    /// 0...1, or nil when the job hasn't reported progress yet.
    var fraction: Double? { currentProgressPercentage.map { $0 / 100 } }
}

/// A folder on the server, for picking a library's location.
struct FileSystemEntry: Decodable, Identifiable, Hashable {
    let name: String?
    let path: String?
    let type: String?

    var id: String { path ?? name ?? UUID().uuidString }
    var isDirectory: Bool { type == "Directory" }
}
