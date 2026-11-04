import SwiftUI

/// The asking, laid out as Seerr's own request panel is: which title, a
/// show's seasons to tick, and (for someone allowed to choose) the server,
/// quality profile and folder the request goes to.
struct RequestPanel: View {
    @ObservedObject var requests: Requests
    let title: SeerrTitle
    let details: SeerrDetails?
    let in4K: Bool
    /// A show's seasons ticked to start with; nil for all that can be asked for.
    var preselected: Set<Int>? = nil
    /// The request was made.
    let done: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: Set<Int> = []
    @State private var servers: [SeerrService] = []
    /// What the viewer picked, each nil while it's left as it comes.
    @State private var pickedServer: Int?
    @State private var pickedProfile: Int?
    @State private var pickedFolder: String?
    @State private var options: SeerrServiceOptions?
    @State private var allowance: SeerrQuota.Allowance?
    @State private var sending = false
    @State private var problem: String?
    @FocusState private var onRequest: Bool

    var body: some View {
        PanelBackdrop {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(heading.uppercased())
                        .font(.app(13, .heavy))
                        .kerning(1.6)
                        .foregroundStyle(Theme.primary.1)
                    Text(details?.displayTitle ?? title.displayTitle)
                        .font(.app(28, .bold))
                        .lineLimit(2)
                }
                if requests.user?.approvedAtOnce(movie: title.isMovie, in4K: in4K) == true {
                    SettingsNote(String(localized: "This request will be approved automatically."), tint: Theme.accent)
                }
                if let limit = allowance?.limit, limit > 0, let left = allowance?.remaining {
                    Text("\(left) of \(limit) requests left", comment: "How much of the viewer's ration of requests remains")
                        .font(.app(16))
                        .foregroundStyle(Theme.textSecondary)
                }
                if !seasons.isEmpty { seasonTable }
                if let server, requests.user?.setsRequestOptions == true { destination(server) }
                if let problem { SettingsNote(problem, tint: Theme.palette[1].0) }
                HStack(spacing: 16) {
                    Button(requestLabel) { send() }
                        .buttonStyle(GradientButtonStyle())
                        .focused($onRequest)
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.ghost)
                    if sending { ProgressView() }
                }
                // The panel's whole width, so down from a chip at the far
                // end of its row still finds them.
                .frame(maxWidth: .infinity, alignment: .leading)
                .tvFocusSection()
            }
            .frame(maxWidth: width, alignment: .leading)
            // The panel opens on the button that asks, not on the first
            // season above it.
            .defaultFocus($onRequest, true, priority: .userInitiated)
        }
        // The one season it was opened for, where seasons can be asked for
        // singly; on a Seerr that takes only whole shows, all of them.
        .onAppear { chosen = picks ? preselected ?? Set(askable) : Set(askable) }
        .task { await load() }
    }

    /// As wide as the other panels, and no wider than a phone.
    private var width: CGFloat {
        #if !os(tvOS)
        min(CGFloat(900).scaled, AppWindow.size.width - CGFloat(36).scaled * 2 - 24)
        #else
        CGFloat(900).scaled
        #endif
    }

    private var heading: String {
        switch (title.isMovie, in4K) {
        case (true, false): String(localized: "Request Movie", comment: "Heading of the panel that asks for a film")
        case (true, true): String(localized: "Request Movie in 4K", comment: "Heading of the panel that asks for a film's 4K copy")
        case (false, false): String(localized: "Request Show", comment: "Heading of the panel that asks for a TV show")
        case (false, true): String(localized: "Request Show in 4K", comment: "Heading of the panel that asks for a TV show in 4K")
        }
    }

    // MARK: A show's seasons

    private var specials: Bool { requests.settings?.enableSpecialEpisodes == true }

    private var seasons: [SeerrDetails.Season] {
        title.isMovie ? [] : details?.seasons(specials: specials) ?? []
    }

    private var askable: [Int] {
        title.isMovie ? [] : details?.askableSeasons(in4K: in4K, specials: specials) ?? []
    }

    /// Whether seasons can be asked for one by one: Seerr can be set to take
    /// a show whole or not at all.
    private var picks: Bool { requests.settings?.partialRequestsEnabled != false }

    @ViewBuilder
    private var seasonTable: some View {
        // A few seasons take the room they need; a long run of them scrolls
        // in what a panel can spare.
        if seasons.count <= 6 {
            seasonRows
        } else {
            ScrollView { seasonRows }
                .frame(height: CGFloat(360).scaled)
        }
    }

    private var seasonRows: some View {
        VStack(spacing: 8) {
            if picks, askable.count > 1 {
                let all = chosen.count == askable.count
                row(ticked: all, name: String(localized: "All Seasons", comment: "Ticks every season of a show at once"),
                    detail: nil, badge: nil) {
                    chosen = all ? [] : Set(askable)
                }
            }
            ForEach(seasons, id: \.seasonNumber) { season in
                let number = season.seasonNumber
                let standing = details?.standing(ofSeason: number, in4K: in4K) ?? .unasked
                row(ticked: standing == .unasked ? chosen.contains(number) : nil,
                    name: season.name ?? String(localized: "Season \(number)"),
                    detail: season.episodeCount.map { $0 == 1 ? String(localized: "1 episode") : String(localized: "\($0) episodes") },
                    badge: standing.badge) {
                    guard standing == .unasked, picks else { return }
                    if chosen.contains(number) { chosen.remove(number) } else { chosen.insert(number) }
                }
            }
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 6)
    }

    /// A line of the table: a tick box (none for a season that's there or
    /// asked for already), the season, how long it is, and where it stands.
    private func row(ticked: Bool?, name: String, detail: String?, badge: SeerrBadge?,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: ticked == true ? "checkmark.square.fill" : "square")
                    .opacity(ticked == nil ? 0 : 1)
                Text(name)
                Spacer()
                if let badge {
                    SeerrBadgeView(badge: badge)
                } else if let detail {
                    Text(detail).foregroundStyle(Theme.textSecondary)
                }
            }
            .font(.app(18, .medium))
            .padding(.horizontal, CGFloat(18).scaled)
            .padding(.vertical, CGFloat(10).scaled)
        }
        .buttonStyle(SettingsRowStyle())
    }

    // MARK: Where it goes

    /// The server the request goes to: the one picked, or the one Seerr
    /// sends this kind to by default.
    private var server: SeerrService? {
        servers.first { $0.id == pickedServer } ?? servers.first { $0.isDefault == true } ?? servers.first
    }

    @ViewBuilder
    private func destination(_ server: SeerrService) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if servers.count > 1 {
                choice(String(localized: "Destination Server", comment: "Which Radarr or Sonarr a request is sent to")) {
                    ForEach(servers) { one in
                        Button(one.name) {
                            guard one.id != server.id else { return }
                            // Another server has profiles and folders of its own.
                            pickedServer = one.id
                            pickedProfile = nil
                            pickedFolder = nil
                            options = nil
                        }
                        .buttonStyle(.chip(active: one.id == server.id))
                    }
                }
            }
            if let options {
                if options.profiles.count > 1 {
                    choice(String(localized: "Quality Profile", comment: "The quality a requested title is fetched in")) {
                        ForEach(options.profiles) { profile in
                            Button(profile.name) { pickedProfile = profile.id }
                                .buttonStyle(.chip(active: profile.id == (pickedProfile ?? server.activeProfileId)))
                        }
                    }
                }
                if options.rootFolders.count > 1 {
                    choice(String(localized: "Root Folder", comment: "The folder on the server a requested title is put in")) {
                        ForEach(options.rootFolders) { folder in
                            Button(Self.name(of: folder)) { pickedFolder = folder.path }
                                .buttonStyle(.chip(active: folder.path == (pickedFolder ?? server.activeDirectory)))
                        }
                    }
                } else if let folder = options.rootFolders.first {
                    // Nothing to choose between: said, as Seerr says it.
                    Text(verbatim: String(localized: "Root Folder", comment: "The folder on the server a requested title is put in")
                         + ": " + Self.name(of: folder))
                        .font(.app(15))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        // The profiles and folders of whichever server it is now.
        .task(id: server.id) {
            guard let client = await requests.ready() else { return }
            options = await client.options(of: server, movies: title.isMovie)
        }
    }

    private func choice<Chips: View>(_ name: String, @ViewBuilder chips: () -> Chips) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(name)
                .font(.app(15, .semibold))
                .foregroundStyle(Theme.textSecondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) { chips() }
                    .padding(.vertical, 10)   // room for the focused chip's lift
                    .padding(.horizontal, 6)
            }
        }
        // Up and down land on the row, not on whichever chip lines up.
        .tvFocusSection()
    }

    /// A folder with the room there is in it: "/data/movies (28.5 TB free)".
    private static func name(of folder: SeerrServiceOptions.Folder) -> String {
        guard let free = folder.freeSpace, free > 0 else { return folder.path }
        let room = ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .binary)
        return String(localized: "\(folder.path) (\(room) free)",
                      comment: "A folder and the free space in it: the placeholders are its path and a size like 28.5 TB")
    }

    // MARK: Asking

    private var requestLabel: String {
        let plain = String(localized: "Request", comment: "Asks for a film or show to be added to the library")
        guard !title.isMovie, !chosen.isEmpty, chosen.count != seasons.count else { return plain }
        if chosen.count == 1, let only = chosen.first {
            return String(localized: "Request Season \(only)", comment: "Asks for one season of a show; the placeholder is its number")
        }
        return String(localized: "Request \(chosen.count) Seasons", comment: "Asks for the chosen seasons of a show; always two or more")
    }

    private func send() {
        guard !sending else { return }
        problem = nil
        if !title.isMovie, chosen.isEmpty, !askable.isEmpty {
            problem = String(localized: "Choose a season to ask for.")
            return
        }
        sending = true
        // Every season there is, said as "all": Seerr then takes new ones too.
        let picked = title.isMovie || chosen.count == seasons.count ? nil : chosen.sorted()
        // Only what was changed is said: left alone, Seerr sends a title
        // where it would have (an anime to its own profile and folder).
        var overrides = SeerrRequestOptions()
        if requests.user?.setsRequestOptions == true, let server {
            if servers.first(where: { $0.isDefault == true })?.id != server.id { overrides.serverId = server.id }
            if let pickedProfile, pickedProfile != server.activeProfileId { overrides.profileId = pickedProfile }
            if let pickedFolder, pickedFolder != server.activeDirectory { overrides.rootFolder = pickedFolder }
        }
        let options = overrides
        Task {
            defer { sending = false }
            guard let client = await requests.ready() else {
                problem = String(localized: "Seerr couldn't be reached.")
                return
            }
            do {
                try await client.request(title, tvdbId: details?.tvdbId, seasons: picked, in4K: in4K, options: options)
                done()
                dismiss()
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func load() async {
        guard let client = await requests.ready(), let user = requests.user else { return }
        async let quota = client.quota(of: user)
        if user.setsRequestOptions {
            servers = await client.servers(movies: title.isMovie, in4K: in4K)
        }
        let rations = await quota
        allowance = title.isMovie ? rations?.movie : rations?.tv
    }
}
