import SwiftUI

/// Settings → Plugins: the server's plugins, and the ones its repositories
/// offer. Jellyfin and administrators only. The app sends the server requests
/// and nothing more: the server fetches, installs and runs the plugins, as its
/// own dashboard would have it do. Adding repositories is left to that
/// dashboard.
@MainActor
final class PluginsModel: ObservableObject {
    static let shared = PluginsModel()

    @Published private(set) var installed: [ServerPlugin] = []
    @Published private(set) var catalog: [PluginPackage] = []
    @Published private(set) var restart: ServerRestartState?
    @Published private(set) var loaded = false
    @Published private(set) var restarting = false
    /// The plugin a change is being made to.
    @Published private(set) var working: String?
    /// Plugins turned on or off here since the last restart (see PluginEntry.askedOn).
    @Published private(set) var asked: [String: Bool] = [:]
    @Published var note: String?

    /// A restart is waiting: the server says so, or a plugin is waiting for one
    /// (the server doesn't count turning a plugin off or on).
    var restartWaiting: Bool {
        restart?.pendingRestart == true || installed.contains { ["Restart", "Deleted"].contains($0.status ?? "") }
    }

    private var serverVersion: String { restart?.version ?? "0" }

    /// Installed ones first, by name; one entry for each plugin, its newest
    /// version where the server lists more than one (an update waiting).
    var installedEntries: [PluginEntry] {
        let newest = Dictionary(grouping: installed, by: \.key).compactMap { _, versions in
            versions.max { PluginVersion($0.version) < PluginVersion($1.version) }
        }
        return newest
            .map { plugin in
                PluginEntry(installed: plugin, package: catalog.first { $0.key == plugin.key }, serverVersion: serverVersion,
                            askedOn: plugin.status == "Restart" ? asked[plugin.key] : nil)
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// What isn't installed, by the catalog's kinds.
    var catalogSections: [(title: String, entries: [PluginEntry])] {
        let have = Set(installed.map(\.key))
        let offered = catalog.filter { !have.contains($0.key) }
        return Dictionary(grouping: offered, by: \.categoryLabel)
            .map { title, packages in
                (title, packages.map { PluginEntry(installed: nil, package: $0, serverVersion: serverVersion) }
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
            }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func entry(_ id: String) -> PluginEntry? {
        installedEntries.first { $0.id == id }
            ?? catalog.first { $0.key == id }.map { PluginEntry(installed: nil, package: $0, serverVersion: serverVersion) }
    }

    /// Whose plugins these are: the server and the account they were read as.
    private var loadedFor: String?

    func load(_ client: MediaServer?) async {
        guard let client else { return }
        let whose = "\(client.baseURL.absoluteString)|\(client.userId ?? "")"
        if loadedFor != whose { forget() }
        loadedFor = whose
        do {
            async let plugins = client.serverPlugins()
            async let state = client.serverRestartState()
            installed = try await plugins
            restart = try await state
        } catch {
            note = String(localized: "Couldn't read the server's plugins: \(error.localizedDescription)",
                          comment: "Settings, Plugins: the server's list couldn't be read")
        }
        loaded = true
        // The catalog comes from the internet by way of the server, and can be slow.
        if let offered = try? await client.pluginCatalog() { catalog = offered }
    }

    func install(_ entry: PluginEntry, client: MediaServer?) async {
        guard let client, let package = entry.package, let release = entry.available else { return }
        let updating = entry.installed != nil
        await change(entry, client: client) {
            try await client.installPlugin(package, release: release)
            note = updating
                ? String(localized: "Updating \(entry.name) to \(release.version). Restart the server to finish.",
                         comment: "Settings, Plugins: the placeholders are a plugin's name and the version it's updating to")
                : String(localized: "Installing \(entry.name). Restart the server to start using it.",
                         comment: "Settings, Plugins: the placeholder is a plugin's name")
        } failed: {
            String(localized: "Couldn't install \(entry.name): \($0)", comment: "Settings, Plugins: the placeholders are a plugin's name and what went wrong")
        }
    }

    func setOn(_ entry: PluginEntry, _ on: Bool, client: MediaServer?) async {
        guard let client, let plugin = entry.installed else { return }
        await change(entry, client: client) {
            try await client.setPlugin(plugin, on: on)
            asked[entry.id] = on
            note = on
                ? String(localized: "\(entry.name) is on. Restart the server if it doesn't start working.",
                         comment: "Settings, Plugins: a plugin was turned on; the placeholder is its name")
                : String(localized: "\(entry.name) is off. Restart the server to finish.",
                         comment: "Settings, Plugins: a plugin was turned off; the placeholder is its name")
        } failed: {
            String(localized: "Couldn't change \(entry.name): \($0)", comment: "Settings, Plugins: the placeholders are a plugin's name and what went wrong")
        }
    }

    func uninstall(_ entry: PluginEntry, client: MediaServer?) async {
        guard let client, let plugin = entry.installed, plugin.removable else { return }
        await change(entry, client: client) {
            try await client.uninstallPlugin(plugin)
            note = String(localized: "\(entry.name) will be removed when the server restarts.",
                          comment: "Settings, Plugins: the placeholder is a plugin's name")
        } failed: {
            String(localized: "Couldn't remove \(entry.name): \($0)", comment: "Settings, Plugins: the placeholders are a plugin's name and what went wrong")
        }
    }

    private func change(_ entry: PluginEntry, client: MediaServer, _ work: () async throws -> Void,
                        failed: (String) -> String) async {
        working = entry.id
        note = nil
        do {
            try await work()
        } catch {
            note = failed(error.localizedDescription)
        }
        // A moment for the server to take it in before it's read again.
        try? await Task.sleep(for: .seconds(1))
        if let plugins = try? await client.serverPlugins() { installed = plugins }
        if let state = try? await client.serverRestartState() { restart = state }
        working = nil
    }

    /// Restarts the server, then waits for it to answer again (a minute or so).
    func restartServer(client: MediaServer?) async {
        guard let client else { return }
        restarting = true
        note = nil
        do {
            try await client.restartServer()
        } catch {
            restarting = false
            note = String(localized: "Couldn't restart the server: \(error.localizedDescription)",
                          comment: "Settings, Plugins: the restart request failed")
            return
        }
        try? await Task.sleep(for: .seconds(6))
        var back = false
        for _ in 0..<60 {
            if (try? await client.serverRestartState()) != nil { back = true; break }
            try? await Task.sleep(for: .seconds(3))
        }
        restarting = false
        if back {
            asked = [:]
            await load(client)
            note = String(localized: "The server has restarted.", comment: "Settings, Plugins: the server is back after a restart")
        } else {
            note = String(localized: "The server hasn't come back yet. Look at it on the computer it runs on.",
                          comment: "Settings, Plugins: three minutes after a restart the server still doesn't answer")
        }
    }

    /// A new server, or a new account on it: nothing of the last one's.
    func forget() {
        installed = []
        catalog = []
        restart = nil
        loaded = false
        note = nil
        asked = [:]
    }
}

struct PluginSettingsView: View {
    @EnvironmentObject var app: AppState
    @Binding var path: NavigationPath
    @ObservedObject private var model = PluginsModel.shared
    @State private var confirmingRestart = false

    var body: some View {
        SettingsPage(title: String(localized: "Plugins", comment: "Settings tile and page: the server's plugins"), accent: Theme.palette[3]) {
            Text("Plugins add to what your server does: fetching artwork and subtitles, finding intros, signing people in. Your server installs and runs them; a restart puts a change into use.",
                 comment: "Settings, Plugins: what the page is for")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            PluginRestartBanner(model: model, confirming: $confirmingRestart)

            if let note = model.note {
                SettingsNote(note, tint: Theme.primary.1)
            }

            SettingsColumn(alignment: .leading) {
                if !model.loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120).focusable()
                } else {
                    PluginHeading(String(localized: "INSTALLED", comment: "Settings, Plugins: heading over the plugins the server has, shown in capitals"))
                    ForEach(model.installedEntries) { entry in
                        PluginRow(entry: entry, subtitle: PluginText.summary(of: entry)) {
                            path.append(SettingsRoute.plugin(entry.id))
                        }
                    }
                    if model.catalog.isEmpty {
                        PluginHeading(String(localized: "CATALOG", comment: "Settings, Plugins: heading over the plugins the server's repositories offer, shown in capitals"))
                        ProgressView().frame(maxWidth: .infinity, minHeight: 80)
                    }
                    ForEach(model.catalogSections, id: \.title) { section in
                        PluginHeading(section.title.uppercased())
                        ForEach(section.entries) { entry in
                            PluginRow(entry: entry, subtitle: PluginText.summary(of: entry)) {
                                path.append(SettingsRoute.plugin(entry.id))
                            }
                        }
                    }
                }
            }
        }
        .task { await model.load(app.client) }
        .pluginRestartConfirmation(isPresented: $confirmingRestart) {
            Task { await model.restartServer(client: app.client) }
        }
    }
}

/// One plugin: what it does, and what can be done with it.
struct PluginDetailView: View {
    @EnvironmentObject var app: AppState
    let id: String
    @ObservedObject private var model = PluginsModel.shared
    @State private var confirmingRemove = false
    @State private var confirmingRestart = false

    var body: some View {
        let entry = model.entry(id)
        SettingsPage(title: entry?.name ?? "", accent: Theme.palette[3]) {
            if let entry {
                HStack(alignment: .center, spacing: 20) {
                    PluginPicture(url: entry.image, side: 72)
                    VStack(alignment: .leading, spacing: 6) {
                        if let owner = entry.package?.owner, !owner.isEmpty {
                            Text("By \(owner)", comment: "Settings, Plugins: who makes a plugin; the placeholder is a name")
                                .font(.app(16, .semibold))
                                .foregroundStyle(Theme.textSecondary)
                        }
                        Text(PluginText.summary(of: entry))
                            .font(.app(16))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if let about = entry.package?.overview ?? entry.package?.description ?? entry.installed?.description, !about.isEmpty {
                    Text(about)
                        .font(.app(18))
                        .fixedSize(horizontal: false, vertical: true)
                }

                PluginRestartBanner(model: model, confirming: $confirmingRestart)
                if let note = model.note {
                    SettingsNote(note, tint: Theme.primary.1)
                }

                HStack(spacing: 14) {
                    if let release = entry.available {
                        Button(entry.installed == nil
                               ? String(localized: "Install", comment: "Settings, Plugins: installs a plugin on the server")
                               : String(localized: "Update to \(release.version)", comment: "Settings, Plugins: the placeholder is the newer version")) {
                            Task { await model.install(entry, client: app.client) }
                        }
                        .buttonStyle(.chip(active: true))
                    }
                    if entry.installed != nil {
                        Button(entry.isOn ? String(localized: "Turn Off", comment: "Settings, Plugins: turns an installed plugin off")
                                          : String(localized: "Turn On", comment: "Settings, Plugins: turns an installed plugin back on")) {
                            Task { await model.setOn(entry, !entry.isOn, client: app.client) }
                        }
                        .buttonStyle(.chip(active: false))
                    }
                    if model.working == entry.id { ProgressView() }
                }
                .disabled(model.working != nil || model.restarting)
                .tvFocusSection()

                if entry.needsNewerServer {
                    SettingsNote(String(localized: "Every release of this plugin needs a newer version of the server.",
                                        comment: "Settings, Plugins: a catalog plugin the server is too old for"),
                                 tint: Theme.textSecondary)
                }

                if let release = entry.available, let changes = release.changelog?.trimmingCharacters(in: .whitespacesAndNewlines), !changes.isEmpty {
                    PluginHeading(String(localized: "WHAT'S NEW IN \(release.version)", comment: "Settings, Plugins: heading over a release's changes, shown in capitals; the placeholder is its version"))
                    Text(changes)
                        .font(.app(16))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if let plugin = entry.installed, plugin.removable, plugin.status != "Deleted" {
                    Button(String(localized: "Remove Plugin", comment: "Settings, Plugins: uninstalls a plugin from the server")) {
                        confirmingRemove = true
                    }
                    .buttonStyle(.signOut)
                    .disabled(model.working != nil || model.restarting)
                    .padding(.top, 10)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120).focusable()
            }
        }
        // Opened straight to it (a link, or the list under it not drawn): the
        // plugins read here too.
        .task { if model.entry(id) == nil { await model.load(app.client) } }
        .confirmationDialog(String(localized: "Remove \(entry?.name ?? "") from the server?", comment: "Settings, Plugins: confirming an uninstall; the placeholder is a plugin's name"),
                            isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button(String(localized: "Remove Plugin", comment: "Settings, Plugins: uninstalls a plugin from the server"), role: .destructive) {
                if let entry { Task { await model.uninstall(entry, client: app.client) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its settings on the server go with it. It can be installed again from the catalog.",
                 comment: "Settings, Plugins: what removing a plugin means")
        }
        .pluginRestartConfirmation(isPresented: $confirmingRestart) {
            Task { await model.restartServer(client: app.client) }
        }
    }
}

// MARK: - Pieces

/// A restart is waiting: what's waiting for it, and the button. While the
/// server restarts, a line saying so.
private struct PluginRestartBanner: View {
    @ObservedObject var model: PluginsModel
    @Binding var confirming: Bool

    var body: some View {
        if model.restarting {
            HStack(spacing: 12) {
                ProgressView()
                Text("Restarting the server…", comment: "Settings, Plugins: shown while the server restarts")
                    .font(.app(18, .semibold))
            }
            .padding(.horizontal, CGFloat(22).scaled)
            .padding(.vertical, CGFloat(18).scaled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
        } else if model.restartWaiting, let restart = model.restart {
            VStack(alignment: .leading, spacing: 12) {
                Label {
                    Text("The server needs a restart to put the changes to its plugins into use.",
                         comment: "Settings, Plugins: a restart is waiting")
                } icon: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                }
                .font(.app(17, .semibold))
                .foregroundStyle(Theme.palette[1].0)
                if restart.canRestart {
                    Button(String(localized: "Restart Server", comment: "Settings, Plugins: restarts the server")) { confirming = true }
                        .buttonStyle(.chip(active: true))
                } else {
                    Text("Restart it on the computer it runs on.", comment: "Settings, Plugins: a server that can't restart itself")
                        .font(.app(16))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.horizontal, CGFloat(22).scaled)
            .padding(.vertical, CGFloat(18).scaled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .tvFocusSection()
        }
    }
}

private extension View {
    func pluginRestartConfirmation(isPresented: Binding<Bool>, restart: @escaping () -> Void) -> some View {
        confirmationDialog(String(localized: "Restart the server?", comment: "Settings, Plugins: confirming a server restart"),
                           isPresented: isPresented, titleVisibility: .visible) {
            Button(String(localized: "Restart Server", comment: "Settings, Plugins: restarts the server"), action: restart)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anyone watching is stopped until it's back, in a minute or so.",
                 comment: "Settings, Plugins: what a server restart means for whoever's watching")
        }
    }
}

private struct PluginHeading: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(verbatim: text)
            .font(.app(12, .heavy))
            .kerning(1.6)
            .foregroundStyle(Theme.palette[3].1)
            .padding(.top, 10)
    }
}

private struct PluginRow: View {
    let entry: PluginEntry
    let subtitle: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                PluginPicture(url: entry.image, side: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text(entry.name).font(.app(20, .semibold)).lineLimit(1)
                    Text(subtitle)
                        .font(.app(14))
                        .foregroundStyle(entry.available != nil && entry.installed != nil ? Theme.palette[3].1 : Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.app(14, .bold))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .padding(.horizontal, CGFloat(22).scaled)
            .padding(.vertical, CGFloat(18).scaled)
        }
        .buttonStyle(SettingsRowStyle())
    }
}

/// The catalog's picture of a plugin, or a puzzle piece where it has none.
private struct PluginPicture: View {
    let url: URL?
    let side: CGFloat

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image {
                image.resizable().scaledToFill()
            } else {
                Image(systemName: "puzzlepiece.extension.fill")
                    .font(.app(side * 0.42, .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.gradient(Theme.palette[3], start: .topLeading, end: .bottomTrailing))
            }
        }
        .frame(width: CGFloat(side).scaled, height: CGFloat(side).scaled)
        .clipShape(RoundedRectangle(cornerRadius: CGFloat(side).scaled * 0.28))
    }
}

enum PluginText {
    /// "12.0.6 · On · Update to 12.0.7", "Built in · On", "Subtitles · by jellyfin".
    static func summary(of entry: PluginEntry) -> String {
        var parts: [String] = []
        if let plugin = entry.installed {
            parts.append(plugin.removable ? plugin.version : String(localized: "Built in", comment: "Settings, Plugins: a plugin the server comes with"))
            parts.append(status(plugin, askedOn: entry.askedOn))
            if let release = entry.available {
                parts.append(String(localized: "Update to \(release.version)", comment: "Settings, Plugins: the placeholder is the newer version"))
            }
        } else if entry.needsNewerServer {
            parts.append(String(localized: "Needs a newer server", comment: "Settings, Plugins: a plugin the server is too old to run"))
        } else if let release = entry.available {
            parts.append(release.version)
            if let repository = release.repositoryName, !repository.isEmpty { parts.append(repository) }
        }
        return parts.joined(separator: " · ")
    }

    static func status(_ plugin: ServerPlugin, askedOn: Bool? = nil) -> String {
        if plugin.status == "Restart", let askedOn {
            return askedOn
                ? String(localized: "On after a restart", comment: "Settings, Plugins: turned on here, in use once the server restarts")
                : String(localized: "Off after a restart", comment: "Settings, Plugins: turned off here, stops once the server restarts")
        }
        return switch plugin.status {
        case "Disabled": String(localized: "Off", comment: "Settings tile subtitle: iCloud Sync is off")
        case "Restart": String(localized: "Waiting for a restart", comment: "Settings, Plugins: a change to the plugin takes effect when the server restarts")
        case "Deleted": String(localized: "Removed when the server restarts", comment: "Settings, Plugins: an uninstalled plugin still loaded until a restart")
        case "Superceded": String(localized: "Replaced by a newer version", comment: "Settings, Plugins: an old version of a plugin after an update")
        case "Malfunctioned": String(localized: "Not working", comment: "Settings, Plugins: the server couldn't load the plugin")
        case "NotSupported": String(localized: "Needs a newer server", comment: "Settings, Plugins: a plugin the server is too old to run")
        default: String(localized: "On")
        }
    }
}
