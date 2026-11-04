import Foundation

/// A library + filter combination saved for one-press access: in the menu,
/// as a row of its own on Home, or both.
struct PinnedFilter: Codable, Identifiable, Hashable {
    var id = UUID()
    let libraryId: String
    let libraryName: String
    let collectionType: String?
    let filters: LibraryFilters
    /// A name the user typed in place of the automatic one.
    var customName: String?
    /// Listed in the menu (and so a choice for a phone's tab bar). Every pin
    /// was, before Home could have them.
    var inMenu = true
    /// A row of its own on Home (see `HomeLayout.pinned`).
    var onHome = false

    private enum CodingKeys: String, CodingKey {
        case id, libraryId, libraryName, collectionType, filters, customName, inMenu, onHome
    }

    var title: String {
        if let customName, !customName.isEmpty { return customName }
        return automaticTitle
    }

    /// Most distinctive part first, since long names get cut off in the menu:
    /// e.g. "1990s Horror Movies · Unwatched", "Shows · Recently Added".
    var automaticTitle: String {
        let decades = filters.decades.sorted().map(LibraryFilters.decadeName).joined(separator: ", ")
        let genres = filters.genreList.joined(separator: ", ")
        // The chosen shows stand for the library: "Bluey, Peppa Pig · Episodes".
        let shows = filters.showList
        let what = shows.isEmpty ? libraryName
            : shows.count <= 2 ? shows.joined(separator: ", ")
            : String(localized: "\(shows.count) shows", comment: "Filter chip: how many shows are chosen")
        var parts = [[decades, genres, what].filter { !$0.isEmpty }.joined(separator: " ")]
        if filters.episodes { parts.append(String(localized: "Episodes", comment: "Part of a pinned filter's name: the library is listed by episode")) }
        if filters.unwatched { parts.append(String(localized: "Unwatched", comment: "Part of a pinned filter's name: only items not yet watched")) }
        if filters.favorites { parts.append(String(localized: "Favourites", comment: "Part of a pinned filter's name: only favorited items")) }
        if filters.sort != .title { parts.append(filters.sort.label) }
        if filters.reversed { parts.append(filters.sort.order(reversed: true)) }
        return parts.joined(separator: " · ")
    }

    var icon: String {
        if filters.episodes { return "play.rectangle.fill" }
        if !filters.shows.isEmpty { return "tv.fill" }
        if !filters.genres.isEmpty { return "theatermasks.fill" }
        if !filters.decades.isEmpty { return "calendar" }
        if filters.favorites { return "star.fill" }
        if filters.unwatched { return "eye.slash.fill" }
        return "line.3.horizontal.decrease.circle.fill"
    }
}

extension PinnedFilter {
    /// Pins saved before Home could have them have neither switch: they stay
    /// in the menu, and off Home.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        libraryId = try c.decode(String.self, forKey: .libraryId)
        libraryName = try c.decode(String.self, forKey: .libraryName)
        collectionType = try c.decodeIfPresent(String.self, forKey: .collectionType)
        filters = try c.decode(LibraryFilters.self, forKey: .filters)
        customName = try c.decodeIfPresent(String.self, forKey: .customName)
        inMenu = try c.decodeIfPresent(Bool.self, forKey: .inMenu) ?? true
        onHome = try c.decodeIfPresent(Bool.self, forKey: .onHome) ?? false
    }
}

/// The menu's movable sections, in the order they're listed. Settings isn't
/// here: it stays at the foot of the menu.
enum MenuSection: String, Codable, CaseIterable {
    /// `watchlist` is the films marked to be watched: beside Favourites in a
    /// menu left as it comes, and at the end of one someone has already put
    /// in their own order (as any section added later is). `liveTV` is the
    /// server's television channels, under the libraries: there only where
    /// the server has a tuner, and not turned off in Settings. `search`
    /// comes first, above Home, in a menu left as it comes (it was last
    /// until 1.4); one already put in its own order keeps that order.
    case search, home, libraries, liveTV, favorites, watchlist, collections
}
