import SwiftUI

extension Notification.Name {
    /// A playlist of songs was made, changed or deleted here. Pages listing
    /// playlists, or a playlist's songs, ask again; the object is the
    /// playlist's id, where there's one playlist to name.
    static let songPlaylistsChanged = Notification.Name("goosetv.songPlaylistsChanged")
}

/// A song in an album's or a playlist's list, told apart from the same song
/// further down: a playlist may hold a song twice, and the server names both
/// places by the song's id.
struct PlaylistRow: Identifiable {
    let id = UUID()
    let song: BaseItem

    /// The rows as they're drawn: their ids, for focus and scrolling.
    var key: String { id.uuidString }
}

/// Songs, films or episodes on their way into a playlist or a collection:
/// what they are, to head the panel with, and how to have them, asked once
/// one has been chosen.
struct PlaylistAddition: Identifiable {
    /// What they go into.
    enum Kind {
        case songPlaylist, videoPlaylist, collection

        /// What a playlist of them holds, as the server names it.
        var mediaType: String { self == .songPlaylist ? "Audio" : "Video" }
    }

    let id = UUID()
    let item: BaseItem
    var kind: Kind = .songPlaylist
    let items: () async throws -> [BaseItem]

    /// A film, a show, a season or an episode: the item itself, which the
    /// server takes as all of a show's or a season's episodes.
    static func video(_ item: BaseItem, into kind: Kind) -> PlaylistAddition {
        PlaylistAddition(item: item, kind: kind) { [item] }
    }
}

/// Which playlist or collection things go into: one of the account's, or a
/// new one named here.
struct PlaylistPicker: View {
    @Environment(\.appState) private var app
    @Environment(\.dismiss) private var dismiss
    let addition: PlaylistAddition

    @State private var lists: [BaseItem] = []
    @State private var loaded = false
    @State private var naming = false
    /// The one being added to, while they go.
    @State private var adding: String?
    @State private var problem: String?
    @State private var listHeight: CGFloat = 0

    private var isCollection: Bool { addition.kind == .collection }

    var body: some View {
        PanelBackdrop {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(isCollection ? String(localized: "ADD TO COLLECTION", comment: "Heads the panel that chooses a collection for a film or a show, in capitals")
                                      : String(localized: "ADD TO PLAYLIST", comment: "Heads the panel that chooses a playlist for songs, in capitals"))
                        .font(.app(12, .heavy))
                        .kerning(1.6)
                        .foregroundStyle(Theme.primary.1)
                    Text(addition.item.displayTitle)
                        .font(.app(28, .bold))
                        .lineLimit(2)
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)
                ScrollView {
                    VStack(spacing: 6) {
                        row(isCollection ? String(localized: "New Collection…", comment: "Makes a new collection, named next")
                                         : String(localized: "New Playlist…", comment: "Makes a new playlist of songs, named next"),
                            icon: "plus") {
                            naming = true
                        }
                        if !loaded {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                        }
                        ForEach(lists) { list in
                            row(list.displayTitle, icon: icon, detail: list.childCount.map(count), busy: adding == list.id) {
                                add(to: list)
                            }
                        }
                    }
                    // Room for a focused row's lift.
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
                }
                // As tall as its rows, up to a point: a scroll view alone
                // takes all the height it's offered.
                .frame(height: min(max(listHeight, 80), CGFloat(Theme.isPhone ? 420 : 560).scaled))
                if let problem {
                    Text(problem)
                        .font(.app(16))
                        .foregroundStyle(Theme.palette[1].0)
                        .padding(.horizontal, 6)
                }
            }
            .frame(width: CGFloat(Theme.isPhone ? 320 : 600).scaled)
        }
        .task { await load() }
        .fullScreenCover(isPresented: $naming) {
            TextEntryPanel(title: isCollection ? String(localized: "New Collection", comment: "Title of the panel naming a new collection")
                                               : String(localized: "New Playlist", comment: "Title of the panel naming a new playlist of songs"),
                           message: String(localized: "What to call it.", comment: "Asks for a new playlist's name"),
                           placeholder: isCollection ? Self.untitledCollection : Self.untitled) { name in
                await create(named: name)
            }
            .presentationBackground(.clear)
        }
    }

    /// What a playlist is called when it's given no name.
    static var untitled: String { String(localized: "My Playlist", comment: "The name a new playlist of songs gets when none is typed") }
    static var untitledCollection: String { String(localized: "My Collection", comment: "The name a new collection gets when none is typed") }

    private var icon: String {
        switch addition.kind {
        case .songPlaylist: "music.note.list"
        case .videoPlaylist: "list.and.film"
        case .collection: "rectangle.stack"
        }
    }

    /// "6 songs", "12 items".
    private func count(_ number: Int) -> String {
        addition.kind == .songPlaylist ? String(localized: "\(number) songs", comment: "How many songs a music library has")
                                       : String(localized: "\(number) items")
    }

    private func row(_ title: String, icon: String, detail: String? = nil, busy: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.app(18, .semibold))
                    .frame(width: CGFloat(24).scaled)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1)
                    if let detail {
                        Text(detail)
                            .font(.app(14))
                            .opacity(0.6)
                    }
                }
                Spacer(minLength: 8)
                if busy { ProgressView() }
            }
        }
        .buttonStyle(MenuRowStyle())
        .focusEffectDisabled()
        .disabled(adding != nil)
    }

    private func load() async {
        guard let client = app?.client else { return }
        lists = (try? await isCollection ? client.boxSets() : client.playlists(mediaType: addition.kind.mediaType)) ?? []
        loaded = true
    }

    private func add(to list: BaseItem) {
        guard adding == nil, let client = app?.client else { return }
        adding = list.id
        problem = nil
        let kind = addition.kind
        Task {
            do {
                let ids = try await addition.items().map(\.id)
                guard !ids.isEmpty else { throw ServerError.badResponse(0) }
                if kind == .collection {
                    try await client.addToCollection(list.id, items: ids)
                } else {
                    try await client.addToPlaylist(list.id, songs: ids)
                }
                NotificationCenter.default.post(name: .songPlaylistsChanged, object: list.id)
                dismiss()
            } catch {
                adding = nil
                problem = String(localized: "Couldn't add to \u{201C}\(list.displayTitle)\u{201D}.",
                                 comment: "The server refused songs for a playlist, or didn't answer; the placeholder is the playlist's name")
            }
        }
    }

    private func create(named typed: String) async {
        guard let client = app?.client else { return }
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        adding = "*new"
        problem = nil
        do {
            let ids = try await addition.items().map(\.id)
            let id: String
            if isCollection {
                id = try await client.createCollection(named: name.isEmpty ? Self.untitledCollection : name, items: ids)
            } else {
                id = try await client.createPlaylist(named: name.isEmpty ? Self.untitled : name, items: ids,
                                                     mediaType: addition.kind.mediaType)
            }
            NotificationCenter.default.post(name: .songPlaylistsChanged, object: id)
            // The first of them brings the menu's Collections row.
            app?.collectionsChanged()
            dismiss()
        } catch {
            adding = nil
            problem = isCollection ? String(localized: "Couldn't make the collection.", comment: "The server refused a new collection, or didn't answer")
                                   : String(localized: "Couldn't make the playlist.", comment: "The server refused a new playlist of songs, or didn't answer")
        }
    }
}

#if !os(tvOS)
/// A playlist's songs to reorder by dragging and take out by swiping, as
/// the touch screen does it (on a Mac, dragging and a right click): each
/// change is sent as it's made.
struct PlaylistEditor: View {
    @Environment(\.dismiss) private var dismiss
    let name: String
    @Binding var rows: [PlaylistRow]
    let move: (_ from: Int, _ to: Int) -> Void
    let remove: (PlaylistRow) -> Void

    var body: some View {
        NavigationStack {
            List {
                ForEach(rows) { row in
                    let song = row.song
                    HStack(spacing: 12) {
                        MusicArt(item: song, maxWidth: 120)
                            .frame(width: 44, height: 44)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(song.displayTitle)
                                .font(.app(17, .semibold))
                                .lineLimit(1)
                            if let artist = song.byLine {
                                Text(artist)
                                    .font(.app(14))
                                    .foregroundStyle(Theme.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .listRowBackground(Color.white.opacity(0.05))
                    #if os(macOS)
                    .contextMenu {
                        Button(String(localized: "Remove from Playlist", comment: "Takes a song out of a playlist; the song stays in the library"),
                               role: .destructive) { remove(row) }
                    }
                    #endif
                }
                .onMove { offsets, destination in
                    guard let from = offsets.first else { return }
                    // Where it ends up, counted once it's out of the list.
                    move(from, destination > from ? destination - 1 : destination)
                }
                .onDelete { offsets in
                    let going = offsets.filter { rows.indices.contains($0) }.map { rows[$0] }
                    for row in going { remove(row) }
                }
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 520, minHeight: 560)
        #endif
        .preferredColorScheme(.dark)
    }
}
#endif
