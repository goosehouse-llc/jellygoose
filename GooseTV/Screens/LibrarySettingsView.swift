import SwiftUI

/// Settings → Libraries: what the server is serving, and the jobs that keep it current.
/// Everything here needs an administrator account, so it says so when it can't act.
struct LibrarySettingsView: View {
    @EnvironmentObject var app: AppState
    @Binding var path: NavigationPath

    @StateObject private var activity = ServerActivity()
    @State private var libraries: [VirtualFolder] = []
    @State private var counts: [String: Int] = [:]
    @State private var loaded = false
    @State private var addingLibrary = false
    @State private var note: String?

    var body: some View {
        SettingsPage(title: String(localized: "Libraries"), accent: Theme.palette[2]) {
            if !app.isAdmin {
                SettingsNote(String(localized: "Only an administrator can change libraries. You're signed in as \(app.userName ?? String(localized: "this user")), which can't.",
                                    comment: "The placeholder is the signed-in user's name"), tint: Theme.palette[1].0)
            }

            HStack(spacing: 14) {
                Button("Scan for changes") { scan() }
                    .buttonStyle(.chip(active: false))
                Button("Add library") { addingLibrary = true }
                    .buttonStyle(.chip(active: false))
            }
            .disabled(!app.isAdmin)
            .tvFocusSection()

            if let running = activity.running {
                ActivityStrip(task: running)
            }
            if let note {
                SettingsNote(note, tint: Theme.primary.1)
            }

            SettingsColumn {
                if !loaded {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120).focusable()
                } else if libraries.isEmpty {
                    SettingsNote(String(localized: "No libraries yet."), tint: Theme.textSecondary)
                }
                ForEach(libraries) { library in
                    SettingsRow(icon: library.kind.icon, accent: Theme.palette[2], title: library.name,
                                subtitle: subtitle(for: library)) {
                        path.append(SettingsRoute.library(library))
                    }
                    .disabled(!app.isAdmin)
                }
            }
        }
        .task {
            await load()
            // Until the page goes, when the task is cancelled with it.
            await activity.watch(app.client)
        }
        // A finished scan changes what's on the shelves.
        .onChange(of: activity.finishedRuns) { _, _ in Task { await load() } }
        .fullScreenCover(isPresented: $addingLibrary) {
            AddLibraryFlow { name, kind, folders in
                await add(name: name, kind: kind, folders: folders)
            }
            .presentationBackground(.clear)
        }
    }

    /// "Movies · 2,177 items · /media/movies"
    private func subtitle(for library: VirtualFolder) -> String {
        var parts = [library.kindLabel]
        if let itemCount = counts[library.id] { parts.append(String(localized: "\(itemCount) items")) }
        parts.append(library.folders.count == 1 ? (library.folders.first ?? "")
                                                : String(localized: "\(library.folders.count) folders"))
        return parts.joined(separator: " · ")
    }

    private func load() async {
        guard let client = app.client else { return }
        do {
            libraries = try await client.libraries()
        } catch {
            note = String(localized: "Couldn't read the libraries: \(error.localizedDescription)")
        }
        loaded = true
        // All at once: one after another, a dozen libraries took a dozen round trips.
        counts = await withTaskGroup(of: (String, Int?).self) { group in
            for library in libraries {
                guard let itemId = library.itemId else { continue }
                group.addTask { (library.id, try? await client.itemCount(inLibrary: itemId, types: library.countedTypes)) }
            }
            var counted = counts
            for await (id, count) in group where count != nil { counted[id] = count }
            return counted
        }
    }

    private func scan() {
        guard let client = app.client else { return }
        note = nil
        Task {
            do {
                try await client.scanLibraries()
                activity.poll()
            } catch {
                note = String(localized: "Couldn't start the scan: \(error.localizedDescription)")
            }
        }
    }

    private func add(name: String, kind: LibraryKind, folders: [String]) async {
        guard let client = app.client else { return }
        do {
            try await client.addLibrary(name: name, kind: kind, folders: folders)
            note = String(localized: "Added \(name). The server is scanning it now.", comment: "The placeholder is a library name")
            await load()
            activity.poll()
        } catch {
            note = String(localized: "Couldn't add the library: \(error.localizedDescription)")
        }
    }
}

// MARK: - One library

struct LibraryDetailView: View {
    @EnvironmentObject var app: AppState
    let library: VirtualFolder

    @Environment(\.dismiss) private var dismiss
    @StateObject private var activity = ServerActivity()
    @State private var folders: [String]
    @State private var name: String
    @State private var renaming = false
    @State private var addingFolder = false
    @State private var removingFolder: String?
    @State private var removingLibrary = false
    @State private var note: String?

    init(library: VirtualFolder) {
        self.library = library
        _folders = State(initialValue: library.folders)
        _name = State(initialValue: library.name)
    }

    var body: some View {
        SettingsPage(title: name, accent: Theme.palette[2]) {
            Text("\(library.kindLabel) library")
                .font(.app(17))
                .foregroundStyle(Theme.textSecondary)

            HStack(spacing: 14) {
                Button("Rename") { renaming = true }
                    .buttonStyle(.chip(active: false))
                Button("Scan this library") { refresh(replacingExisting: false) }
                    .buttonStyle(.chip(active: false))
                Button("Refresh all metadata") { refresh(replacingExisting: true) }
                    .buttonStyle(.chip(active: false))
                Button("Add folder") { addingFolder = true }
                    .buttonStyle(.chip(active: false))
            }
            .tvFocusSection()

            if let running = activity.running {
                ActivityStrip(task: running)
            }
            if let note {
                SettingsNote(note, tint: Theme.primary.1)
            }

            SettingsColumn(alignment: .leading) {
                Text("FOLDERS", comment: "Heading shown in capitals")
                    .font(.app(12, .heavy))
                    .kerning(1.6)
                    .foregroundStyle(Theme.palette[2].1)
                ForEach(folders, id: \.self) { folder in
                    Button { removingFolder = folder } label: {
                        HStack(spacing: 18) {
                            Image(systemName: "folder.fill")
                                .font(.app(19, .semibold))
                                .frame(width: CGFloat(46).scaled, height: CGFloat(46).scaled)
                                .background(Theme.gradient(Theme.palette[2], start: .topLeading, end: .bottomTrailing),
                                            in: RoundedRectangle(cornerRadius: 13))
                            Text(folder).font(.app(18)).lineLimit(1)
                            Spacer()
                            Image(systemName: "minus.circle")
                                .font(.app(18, .bold))
                                .foregroundStyle(Theme.palette[1].0)
                        }
                        .padding(.horizontal, CGFloat(22).scaled)
                        .padding(.vertical, CGFloat(18).scaled)
                    }
                    .buttonStyle(SettingsRowStyle())
                }

                Button("Remove this library") { removingLibrary = true }
                    .buttonStyle(.signOut)
                    .padding(.top, 10)
            }
        }
        // Until the page goes, when the task is cancelled with it.
        .task { await activity.watch(app.client) }
        .fullScreenCover(isPresented: $renaming) {
            TextEntryPanel(title: String(localized: "Rename Library"), message: String(localized: "Shown in the menu and on Home."),
                           placeholder: library.name, initial: name) { newName in
                await rename(to: newName)
            }
            .presentationBackground(.clear)
        }
        .fullScreenCover(isPresented: $addingFolder) {
            FolderPicker { folder in await addFolder(folder) }
                .presentationBackground(.clear)
        }
        .confirmationDialog("Remove this folder from \(name)?",
                            isPresented: $removingFolder.isPresent(),
                            titleVisibility: .visible) {
            Button("Remove folder", role: .destructive) {
                if let folder = removingFolder { Task { await removeFolder(folder) } }
            }
            Button("Cancel", role: .cancel) { removingFolder = nil }
        } message: {
            Text(removingFolder ?? "")
        }
        .confirmationDialog("Remove \(name) from the server?", isPresented: $removingLibrary,
                            titleVisibility: .visible) {
            Button("Remove library", role: .destructive) { Task { await removeLibrary() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The files stay where they are; the server stops serving them.")
        }
    }

    private func refresh(replacingExisting: Bool) {
        guard let client = app.client, let itemId = library.itemId else { return }
        note = nil
        Task {
            do {
                try await client.refreshMetadata(itemId: itemId, replacingExisting: replacingExisting)
                note = replacingExisting
                    ? String(localized: "Refreshing every item's metadata and artwork. This can take a while.")
                    : String(localized: "Looking for new and changed files in \(name).", comment: "The placeholder is a library name")
                activity.poll()
            } catch {
                note = String(localized: "Couldn't start it: \(error.localizedDescription)", comment: "Starting a library scan or metadata refresh failed")
            }
        }
    }

    private func rename(to newName: String) async {
        guard let client = app.client, !newName.isEmpty, newName != name else { return }
        do {
            try await client.renameLibrary(name, to: newName)
            name = newName
            await app.reloadLibraries()
        } catch {
            note = String(localized: "Couldn't rename it: \(error.localizedDescription)", comment: "Renaming a library failed")
        }
    }

    private func addFolder(_ folder: String) async {
        guard let client = app.client, !folders.contains(folder) else { return }
        do {
            try await client.addFolder(folder, toLibrary: name)
            folders.append(folder)
            note = String(localized: "Added \(folder). The server is scanning it now.", comment: "The placeholder is a folder path")
            activity.poll()
        } catch {
            note = String(localized: "Couldn't add the folder: \(error.localizedDescription)")
        }
    }

    private func removeFolder(_ folder: String) async {
        guard let client = app.client else { return }
        removingFolder = nil
        do {
            try await client.removeFolder(folder, fromLibrary: name)
            folders.removeAll { $0 == folder }
        } catch {
            note = String(localized: "Couldn't remove the folder: \(error.localizedDescription)")
        }
    }

    private func removeLibrary() async {
        guard let client = app.client else { return }
        do {
            try await client.removeLibrary(name: name)
            await app.reloadLibraries()
            dismiss()
        } catch {
            note = String(localized: "Couldn't remove the library: \(error.localizedDescription)")
        }
    }
}

// MARK: - What the server is doing

/// Polls the server's background jobs so a scan's progress shows on screen.
@MainActor
final class ServerActivity: ObservableObject {
    @Published private(set) var running: ServerTask?
    /// Bumped whenever a job finishes, so screens can reload what it changed.
    @Published private(set) var finishedRuns = 0

    private var client: (any MediaServer)?

    /// Asks for as long as the task it runs in lasts: a page's `.task`, which
    /// ends with the page. Started and stopped by hand, a start that came
    /// after a slow load outlived the page that asked for it.
    func watch(_ client: (any MediaServer)?) async {
        self.client = client
        while !Task.isCancelled {
            await refresh()
            // Often while a job runs, so its bar moves; seldom while none
            // does, since `poll()` asks at once for one the app starts.
            try? await Task.sleep(for: .milliseconds(running == nil ? 5000 : 1500))
        }
    }

    /// Checks again right away, for when the app has just started a job.
    func poll() {
        Task { await refresh() }
    }

    private func refresh() async {
        guard let client, let tasks = try? await client.serverTasks() else { return }
        let next = tasks.first { $0.isRunning }
        if running != nil, next == nil { finishedRuns += 1 }
        running = next
    }
}

/// "Scan Media Library — 24%" with a bar, while the server works.
struct ActivityStrip: View {
    let task: ServerTask

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ProgressView().scaleEffect(0.8)
                Text(task.name ?? String(localized: "Working", comment: "Shown while the server runs a background job with no name"))
                    .font(.app(19, .semibold))
                Spacer()
                if let fraction = task.fraction {
                    Text("\(Int(fraction * 100))%")
                        .font(.app(19, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.primary.1)
                }
            }
            WatchProgressBar(fraction: task.fraction ?? 0)
        }
        .padding(.horizontal, CGFloat(22).scaled)
        .padding(.vertical, CGFloat(18).scaled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Notes

struct SettingsNote: View {
    let text: String
    let tint: Color

    init(_ text: String, tint: Color) {
        self.text = text
        self.tint = tint
    }

    var body: some View {
        Label(text, systemImage: "info.circle.fill")
            .font(.app(16))
            .foregroundStyle(tint)
    }
}
