import SwiftUI

/// A panel for typing one line (a library's name). tvOS raises its own keyboard
/// when the field is clicked.
struct TextEntryPanel: View {
    let title: String
    let message: String
    let placeholder: String
    let initial: String
    /// Its button's word; Save when nil.
    var action: String? = nil
    let onSave: (String) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @FocusState private var fieldFocused: Bool

    init(title: String, message: String, placeholder: String, initial: String = "", action: String? = nil,
         onSave: @escaping (String) async -> Void) {
        self.title = title
        self.message = message
        self.placeholder = placeholder
        self.initial = initial
        self.action = action
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        PanelBackdrop {
            VStack(alignment: .leading, spacing: 16) {
                Text(title).font(.app(28, .bold))
                Text(message)
                    .font(.app(17))
                    .foregroundStyle(Theme.textSecondary)
                TextField(placeholder, text: $text)
                    .focused($fieldFocused)
                    .padding(.vertical, 6)
                HStack(spacing: 16) {
                    Button {
                        let value = text
                        dismiss()
                        Task { await onSave(value) }
                    } label: {
                        if let action { Text(action) } else { Text("Save") }
                    }
                    .buttonStyle(GradientButtonStyle())
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.ghost)
                }
            }
            // At most this wide: a phone's screen is narrower (it was cut off there).
            .frame(maxWidth: CGFloat(760).scaled, alignment: .leading)
        }
        .onAppear { fieldFocused = true }
    }
}

/// Walks the server's folders so a library can be pointed at one.
struct FolderPicker: View {
    let onPick: (String) async -> Void

    @Environment(\.appState) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var path: String?
    @State private var entries: [FileSystemEntry] = []
    @State private var loading = true

    var body: some View {
        PanelBackdrop {
            VStack(alignment: .leading, spacing: 14) {
                Text("Choose a Folder").font(.app(28, .bold))
                Text(path ?? String(localized: "Server roots", comment: "Top of the server's folder tree, before any folder is opened"))
                    .font(.app(17))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)

                if loading {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 120).focusable()
                } else if entries.isEmpty {
                    Text("Nothing inside this folder.")
                        .font(.app(17))
                        .foregroundStyle(Theme.textSecondary)
                }

                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(entries) { entry in
                            Button { open(entry.path) } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: "folder.fill")
                                        .font(.app(17, .semibold))
                                        .foregroundStyle(Theme.palette[2].1)
                                    Text(entry.name ?? entry.path ?? "—")
                                        .font(.app(19))
                                        .lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.app(13, .bold))
                                        .foregroundStyle(.white.opacity(0.4))
                                }
                            }
                            .buttonStyle(MenuRowStyle())
                            .focusEffectDisabled()
                        }
                    }
                }
                .frame(maxHeight: CGFloat(420).scaled)

                HStack(spacing: 16) {
                    if let path {
                        Button("Use This Folder") {
                            dismiss()
                            Task { await onPick(path) }
                        }
                        .buttonStyle(GradientButtonStyle())
                    }
                    Button(path == nil ? String(localized: "Cancel") : String(localized: "Up One Level")) {
                        if path == nil { dismiss() } else { goUp() }
                    }
                    .buttonStyle(.ghost)
                }
            }
            .frame(maxWidth: CGFloat(900).scaled, alignment: .leading)
        }
        .task { await list(nil) }
    }

    private func open(_ folder: String?) {
        guard let folder else { return }
        Task { await list(folder) }
    }

    private func goUp() {
        guard let path else { return }
        let parent = (path as NSString).deletingLastPathComponent
        Task { await list(parent.isEmpty || parent == path ? nil : parent) }
    }

    private func list(_ folder: String?) async {
        loading = true
        path = folder
        let found = ((try? await app?.client?.serverFolders(at: folder)) ?? []).filter(\.isDirectory)
        // Another folder chosen while this one was on its way: its listing
        // is the one to show, whichever answers last.
        guard path == folder else { return }
        entries = found
        loading = false
    }
}

/// Name it, say what's in it, point it at a folder.
struct AddLibraryFlow: View {
    let onCreate: (String, LibraryKind, [String]) async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var kind: LibraryKind = .movies
    @State private var folders: [String] = []
    @State private var pickingFolder = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        PanelBackdrop {
            VStack(alignment: .leading, spacing: 18) {
                Text("Add Library").font(.app(28, .bold))

                Text("WHAT'S IN IT")
                    .font(.app(12, .heavy)).kerning(1.6)
                    .foregroundStyle(Theme.palette[2].1)
                HStack(spacing: 12) {
                    ForEach(LibraryKind.allCases) { option in
                        Button(option.label) { kind = option }
                            .buttonStyle(.pill(selected: kind == option))
                    }
                }
                .tvFocusSection()

                Text("NAME")
                    .font(.app(12, .heavy)).kerning(1.6)
                    .foregroundStyle(Theme.palette[2].1)
                TextField(kind.label, text: $name)
                    .focused($fieldFocused)

                Text("FOLDERS")
                    .font(.app(12, .heavy)).kerning(1.6)
                    .foregroundStyle(Theme.palette[2].1)
                ForEach(folders, id: \.self) { folder in
                    Text(folder).font(.app(17)).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Button(folders.isEmpty ? String(localized: "Choose a folder") : String(localized: "Add another folder")) { pickingFolder = true }
                    .buttonStyle(.chip(active: false))

                HStack(spacing: 16) {
                    Button("Add Library") {
                        let (chosenName, chosenKind, chosenFolders) = (finalName, kind, folders)
                        dismiss()
                        Task { await onCreate(chosenName, chosenKind, chosenFolders) }
                    }
                    .buttonStyle(GradientButtonStyle())
                    .disabled(folders.isEmpty)
                    Button("Cancel") { dismiss() }
                        .buttonStyle(.ghost)
                }
            }
            .frame(maxWidth: CGFloat(900).scaled, alignment: .leading)
        }
        .fullScreenCover(isPresented: $pickingFolder) {
            FolderPicker { folder in
                if !folders.contains(folder) { folders.append(folder) }
            }
            .presentationBackground(.clear)
        }
    }

    private var finalName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.label : trimmed
    }
}
