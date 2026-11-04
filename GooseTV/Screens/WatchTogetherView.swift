import SwiftUI

/// Watching together (Jellyfin's SyncPlay): the group this device is in and
/// who else is, or a new group to start and the server's groups to join.
/// Once in one, whatever is played is played for everyone in it, from any
/// page, and a pause or a move along the film is everyone's. The groups are
/// the server's, so anyone on the server's own web player, or another app
/// that knows them, can be in the same one.
struct WatchTogetherView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var sync = SyncPlay.shared
    /// The server's groups, as last asked.
    @State private var groups: [SyncPlayGroupInfo] = []
    @State private var loaded = false
    /// Asking the server to start, join or leave a group.
    @State private var busy = false
    /// The film the group is playing, to name.
    @State private var playing: BaseItem?
    /// The page's buttons, for where focus goes as the group comes and goes.
    private enum Control: Hashable { case start, leave }
    @FocusState private var focused: Control?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ShelfHeader(title: SyncPlay.title,
                            eyebrow: String(localized: "In step, on every screen", comment: "Eyebrow above the Watch Together page's title"),
                            accent: Theme.palette[0])
                Text("Watch the same film at the same moment as other people, each on their own screen. Start a group or join one, then play something: it plays for everyone in the group, and a pause or a skip is everyone's.",
                     comment: "Watch Together page: what it does")
                    .font(.app(20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: CGFloat(1100).scaled, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                if let problem = sync.problem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.app(19, .semibold))
                        .foregroundStyle(Theme.palette[1].1)
                }

                if let group = sync.group {
                    inGroup(group)
                } else {
                    outOfGroup
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .pageSides()
        // The server's groups, asked again every few seconds while they're
        // listed: they come and go as others start and leave them.
        .task(id: sync.isInGroup) {
            guard !sync.isInGroup else { return }
            while !Task.isCancelled {
                groups = await sync.groups()
                loaded = true
                try? await Task.sleep(for: .seconds(5))
            }
        }
        // The button pressed is gone from the page once the group has come
        // (or gone), and focus would fall to the menu: onto the way out of
        // the group instead, or the way into another.
        .onChange(of: sync.isInGroup) { _, inGroup in
            app.holdMenuFocus()
            focused = inGroup ? .leave : (sync.access == .create ? .start : nil)
        }
        .task(id: sync.playingItemId) {
            guard let id = sync.playingItemId else { return playing = nil }
            playing = try? await app.client?.item(id: id)
        }
    }

    // MARK: In a group

    private func inGroup(_ group: SyncPlayGroupInfo) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 10) {
                Text(SyncPlay.name(of: group))
                    .font(.app(34, .bold))
                if let playing {
                    Label(String(localized: "Playing \(playing.displayTitle)", comment: "Watch Together page: the film the group is on; the placeholder is its title"),
                          systemImage: "play.rectangle.fill")
                        .font(.app(20, .semibold))
                        .foregroundStyle(Theme.palette[0].1)
                } else {
                    Text("Choose something to play, and it plays for everyone here.",
                         comment: "Watch Together page: in a group with nothing playing yet")
                        .font(.app(20))
                        .foregroundStyle(Theme.textSecondary)
                }
                ForEach(group.participants ?? [], id: \.self) { name in
                    HStack(spacing: 14) {
                        Text(String(name.prefix(1)).uppercased())
                            .font(.app(17, .heavy))
                            .frame(width: CGFloat(40).scaled, height: CGFloat(40).scaled)
                            .background(Theme.gradient(Theme.palette[3], start: .topLeading, end: .bottomTrailing), in: Circle())
                        Text(name)
                            .font(.app(22, .semibold))
                    }
                }
                .padding(.top, 6)
            }
            .padding(CGFloat(28).scaled)
            .frame(maxWidth: CGFloat(900).scaled, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Button {
                act { await sync.leave() }
            } label: {
                Label(SyncPlay.leaveTitle, systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(GradientButtonStyle(colors: Theme.palette[1]))
            .focused($focused, equals: .leave)
            .disabled(busy)
        }
    }

    // MARK: Out of a group

    private var outOfGroup: some View {
        VStack(alignment: .leading, spacing: 22) {
            if sync.access == .create {
                Button {
                    let name = SyncPlay.newGroupName(for: app.userName)
                    act { await sync.create(named: name) }
                } label: {
                    Label(SyncPlay.startTitle, systemImage: "person.2.fill")
                }
                .buttonStyle(GradientButtonStyle(colors: Theme.palette[0]))
                .focused($focused, equals: .start)
                .disabled(busy)
            }

            Text("Groups on this server", comment: "Watch Together page: heading over the groups that can be joined")
                .font(.app(16, .heavy))
                .kerning(1.4)
                .textCase(.uppercase)
                .foregroundStyle(Theme.palette[0].1)
                .padding(.top, 12)

            if !loaded {
                ProgressView()
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if groups.isEmpty {
                Text(sync.access == .create
                     ? String(localized: "No one has started a group. Start one, and others can join it from here or from the server's web player.", comment: "Watch Together page: no groups on the server, for an account that may start one")
                     : SyncPlay.noGroupsTitle)
                    .font(.app(20))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: CGFloat(1100).scaled, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(groups) { group in
                Button {
                    act { await sync.join(group.groupId) }
                } label: {
                    HStack(spacing: 18) {
                        Image(systemName: "person.2")
                            .font(.app(22, .semibold))
                            .frame(width: CGFloat(34).scaled)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(SyncPlay.joinTitle(group))
                                .font(.app(22, .semibold))
                            if let members = SyncPlay.members(of: group) {
                                Text(members)
                                    .font(.app(17))
                                    .opacity(0.7)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, CGFloat(22).scaled)
                    .padding(.vertical, CGFloat(18).scaled)
                    .frame(maxWidth: CGFloat(900).scaled, alignment: .leading)
                }
                .buttonStyle(SettingsRowStyle())
                .disabled(busy)
            }
        }
    }

    private func act(_ work: @escaping () async -> Void) {
        sync.problem = nil
        busy = true
        Task {
            // The menu kept from taking focus while the page changes under it.
            let holding = Task {
                while !Task.isCancelled {
                    app.holdMenuFocus()
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            await work()
            busy = false
            // Now the buttons take focus again: onto the one that's there.
            try? await Task.sleep(for: .milliseconds(100))
            focused = sync.isInGroup ? .leave : (sync.access == .create ? .start : nil)
            try? await Task.sleep(for: .milliseconds(700))
            holding.cancel()
        }
    }
}
