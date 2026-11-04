import SwiftUI

/// An item to open when only its id is known (an episode's series, say).
struct ItemIdRoute: Hashable {
    let id: String
}

/// A music page to open when only its id is known: a song's album, who sang
/// it, a kind of music, or every song someone sings on.
struct MusicRoute: Hashable {
    enum Kind: Hashable { case album, artist, genre, artistSongs }
    let kind: Kind
    let id: String
    /// Shown while the page asks for the rest.
    var name: String? = nil
    /// A genre's library: the genre is the whole server's, its albums the library's.
    var parent: String? = nil
}

/// How a screen deep inside a section opens another one. Pages pushed any other
/// way are invisible to the app's back handling, which pops the section's path —
/// back would then skip the page underneath as well.
///
/// Equal for the same section, since its closures always add to the same path.
/// Made anew on every redraw of the screen around it, closures that can't be
/// compared told every page reading them (a grid, a film's page, its cast)
/// that something had changed, each time the menu opened or closed.
struct SectionNavigator: Equatable {
    /// The section whose path the closures add to.
    var section = ""
    var showPerson: (Person) -> Void = { _ in }
    var showStudio: (Studio) -> Void = { _ in }
    var showItem: (String) -> Void = { _ in }
    var showMusic: (MusicRoute) -> Void = { _ in }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.section == rhs.section }
}

private struct SectionNavigatorKey: EnvironmentKey {
    static let defaultValue = SectionNavigator()
}

extension EnvironmentValues {
    var sectionNavigator: SectionNavigator {
        get { self[SectionNavigatorKey.self] }
        set { self[SectionNavigatorKey.self] = newValue }
    }
}

extension View {
    /// The destinations every section shares. Goes on the stack's content.
    /// A library, collection or playlist opens as a grid of what's in it
    /// (music as music: see `LibraryGridView`); anything else, its page.
    func sectionDestinations() -> some View {
        navigationDestination(for: BaseItem.self) { item in
            if item.isAudiobook {
                AudiobookView(route: BookRoute(id: item.id, title: item.album ?? item.name))
            } else if item.isLibrary || item.isContainer || item.isAlbum || item.isArtist {
                LibraryGridView(library: item)
            } else {
                ItemDetailView(itemId: item.id)
            }
        }
        .navigationDestination(for: MusicRoute.self) { route in
            switch route.kind {
            case .album: AlbumView(albumId: route.id, name: route.name)
            case .artist: ArtistView(artistId: route.id, name: route.name)
            case .genre: GenreView(genreId: route.id, libraryId: route.parent ?? "", name: route.name ?? "")
            case .artistSongs:
                SongListView(title: route.name ?? "", eyebrow: String(localized: "All Songs", comment: "Above a page of every song an artist sings on"),
                             source: route.name) { client in
                    try await client.songs(by: route.id, shuffled: false, limit: 1000)
                }
            }
        }
        .navigationDestination(for: BookRoute.self) { route in
            AudiobookView(route: route)
        }
        .navigationDestination(for: Person.self) { person in
            PersonView(person: person)
        }
        .navigationDestination(for: ItemIdRoute.self) { route in
            ItemDetailView(itemId: route.id)
        }
        .navigationDestination(for: Studio.self) { studio in
            StudioView(studio: studio)
        }
    }

    /// The way in for screens inside the section. Goes on the NavigationStack itself,
    /// since pushed pages don't inherit what's set on the stack's content.
    /// `section` names the path, the same for every screen that shares it.
    func sectionNavigation(path: Binding<NavigationPath>, section: String) -> some View {
        environment(\.sectionNavigator, SectionNavigator(
            section: section,
            showPerson: { path.wrappedValue.append($0) },
            showStudio: { path.wrappedValue.append($0) },
            showItem: { path.wrappedValue.append(ItemIdRoute(id: $0)) },
            showMusic: { path.wrappedValue.append($0) }
        ))
    }
}
