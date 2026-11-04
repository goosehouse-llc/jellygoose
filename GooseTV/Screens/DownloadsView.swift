#if !os(tvOS)
import SwiftUI

/// What's on the device: downloading, done, or failed, with a way to play,
/// retry, cancel and remove each. Works without the server, from what each
/// download kept of its item.
struct DownloadsView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var downloads = Downloads.shared
    @ObservedObject private var smart = SmartDownloads.shared
    @State private var playing: BaseItem?
    @State private var problem: String?
    @AppStorage(PlaybackPreferences.downloadsWiFiOnlyKey) private var wifiOnly = true

    var body: some View {
        // Sorted once a redraw, not once for each place it's read.
        let records = downloads.records.values.sorted { $0.addedAt > $1.addedAt }
        // Films and episodes; songs downloaded by themselves; albums,
        // playlists and books (their songs and parts are listed in them).
        let videos = records.filter { !(downloads.item($0.id)?.isPlayableAudio ?? false) }
        let songs = records.filter { $0.isStandalone && (downloads.item($0.id)?.isPlayableAudio ?? false) }
        let groups = downloads.groups.values.sorted { $0.addedAt > $1.addedAt }
        let listening = !songs.isEmpty || !groups.isEmpty
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("ON THIS DEVICE", comment: "Heading above the downloads, shown in capitals")
                        .font(.app(14, .heavy))
                        .kerning(1.6)
                        .foregroundStyle(Theme.primary.1)
                    Text("Downloads")
                        .font(.app(34, .bold))
                    if !records.isEmpty {
                        Text(ByteCountFormatter.string(fromByteCount: downloads.bytesUsed, countStyle: .file))
                            .font(.app(17))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .padding(.bottom, 4)

                #if os(iOS)
                // A Mac has no mobile data to spare: it downloads on whatever it's on.
                Toggle(isOn: $wifiOnly) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Wi-Fi only")
                            .font(.app(18, .semibold))
                        Text("Downloads wait for Wi-Fi instead of using mobile data. A change applies to downloads started after it.")
                            .font(.app(14))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Theme.accent)
                .padding(14)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.bottom, 10)
                #endif

                DownloadQualityRow()
                    .padding(.bottom, 10)

                if !smart.kept.isEmpty { keptShows }

                if records.isEmpty {
                    Group {
                        #if os(macOS)
                        Text("Nothing downloaded yet. Download a film or an episode from its page or by right-clicking it, or a whole season by right-clicking one of its episodes, to watch it without your server.",
                             comment: "Downloads page on a Mac, when there are none: how to download. A right click opens a title's menu there")
                        #else
                        Text("Nothing downloaded yet. Download a film or an episode from its page or its long-press menu, or a whole season from an episode's long-press menu, to watch it without your server.")
                        #endif
                    }
                        .font(.app(19))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 20)
                }

                if listening, !videos.isEmpty { heading(String(localized: "FILMS AND SHOWS", comment: "Heading above the downloaded films and episodes, in capitals")) }
                ForEach(videos) { record in
                    DownloadRow(record: record) {
                        if let item = downloads.item(record.id) { playing = item }
                    } retry: {
                        Task { await retry(record.id) }
                    }
                }

                if listening {
                    heading(String(localized: "MUSIC AND AUDIOBOOKS", comment: "Heading above the downloaded albums, playlists, songs and audiobooks, in capitals"))
                        .padding(.top, videos.isEmpty ? 0 : 12)
                }
                ForEach(groups) { group in
                    DownloadGroupRow(group: group) {
                        play(group)
                    } retry: {
                        guard let client = app.client as? MediaBrowserClient else { return }
                        Task { problem = await downloads.retry(group: group.id, client: client) }
                    }
                }
                ForEach(songs) { record in
                    DownloadRow(record: record) {
                        if let item = downloads.item(record.id), let client = app.client {
                            MusicPlayer.shared.play([item], client: client)
                        }
                    } retry: {
                        Task { await retry(record.id) }
                    }
                }
            }
            .padding(.horizontal, Theme.pageMargin)
            .padding(.vertical, 32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .playerCover(item: $playing) { PlayerView(item: $0) }
        .alert(problem ?? "", isPresented: $problem.isPresent()) {}
    }

    /// The shows kept downloaded: each with how many of its episodes, and
    /// the way to change that or stop.
    private var keptShows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("KEPT DOWNLOADED", comment: "Heading above the shows whose next episodes are kept on the device, in capitals")
                .font(.app(13, .heavy))
                .kerning(1.6)
                .foregroundStyle(Theme.primary.1)
            ForEach(smart.kept.keys.sorted { (smart.names[$0] ?? "") < (smart.names[$1] ?? "") }, id: \.self) { id in
                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Theme.primary.1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(smart.names[id] ?? "")
                            .font(.app(18, .semibold))
                            .lineLimit(1)
                        Text(SmartDownloads.label(smart.kept[id] ?? 1))
                            .font(.app(14))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer(minLength: 8)
                    KeepDownloadedMenu(seriesId: id, name: smart.names[id] ?? "") {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .frame(width: 44, height: 44)
                    }
                }
                .padding(12)
                .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            Text("The next episodes you haven't watched are kept on this device, and the ones it downloaded are deleted once watched.",
                 comment: "Under the shows kept downloaded: what it means")
                .font(.app(14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 10)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.app(13, .heavy))
            .kerning(1.6)
            .foregroundStyle(Theme.primary.1)
    }

    /// An album or playlist from its first song, a book from where it was
    /// left: from the device, the server or no server.
    private func play(_ group: DownloadGroup) {
        let items = downloads.groupItems(group.id)
        guard !items.isEmpty, let client = app.client else { return }
        if group.kind == .book {
            Audiobooks.play(items, title: group.name, client: client)
        } else {
            MusicPlayer.shared.play(items, source: group.name, client: client)
        }
    }

    private func retry(_ id: String) async {
        guard let item = downloads.item(id), let client = app.client as? MediaBrowserClient else { return }
        problem = await downloads.download(item, client: client)
    }
}

/// How big downloaded films and episodes are: as they are, or a smaller copy
/// the server makes (`DownloadQuality`).
private struct DownloadQualityRow: View {
    @AppStorage(PlaybackPreferences.downloadQualityKey) private var chosen = DownloadQuality.original.rawValue

    var body: some View {
        let quality = DownloadQuality(rawValue: chosen) ?? .original
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Download Quality", comment: "Downloads page: how big downloaded films and episodes are")
                    .font(.app(18, .semibold))
                Group {
                    if let perHour = quality.bytesPerHour {
                        Text("Your server makes a smaller copy of anything bigger, about \(ByteCountFormatter.string(fromByteCount: perHour, countStyle: .file)) an hour. A change applies to downloads started after it.",
                             comment: "Downloads page, under Download Quality. The placeholder is a size, like 1.4 GB")
                    } else {
                        Text("Films and episodes come down as they are on your server, with every audio and subtitle track.",
                             comment: "Downloads page, under Download Quality set to Original")
                    }
                }
                .font(.app(14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Picker(selection: $chosen) {
                ForEach(DownloadQuality.allCases) { Text($0.label).tag($0.rawValue) }
            } label: {
                Text("Download Quality", comment: "Downloads page: how big downloaded films and episodes are")
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .tint(.white)
            .fixedSize()
        }
        .padding(14)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// One download: its picture, what it is, and where it's got to.
private struct DownloadRow: View {
    @ObservedObject private var downloads = Downloads.shared
    let record: DownloadRecord
    let play: () -> Void
    let retry: () -> Void
    @State private var confirmingRemove = false

    private var item: BaseItem? { downloads.item(record.id) }

    var body: some View {
        HStack(spacing: 16) {
            Button(action: tapped) {
                HStack(spacing: 16) {
                    picture
                    VStack(alignment: .leading, spacing: 4) {
                        if let item, item.isEpisode {
                            Text([item.seriesName, item.episodeLabel].compactMap { $0 }.joined(separator: " · "))
                                .font(.app(14, .semibold))
                                .foregroundStyle(Theme.primary.1)
                                .lineLimit(1)
                        }
                        Text(item?.displayTitle ?? "")
                            .font(.app(19, .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        status
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if record.state == .downloading {
                    Task { await downloads.cancel(record.id) }
                } else {
                    confirmingRemove = true
                }
            } label: {
                Image(systemName: record.state == .downloading ? "xmark.circle" : "trash")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(record.state == .downloading ? String(localized: "Cancel Download") : String(localized: "Remove Download"))
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .confirmationDialog(String(localized: "Remove the download?"), isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button(String(localized: "Remove Download"), role: .destructive) { downloads.remove(record.id) }
        } message: {
            Text("It stays on your server; only the copy on this device goes.")
        }
    }

    private func tapped() {
        switch record.state {
        case .done: play()
        case .failed: retry()
        case .downloading: break
        }
    }

    private var picture: some View {
        let episode = item?.isEpisode ?? false
        return Group {
            // Read and decoded off the main thread, and kept, by the image
            // pipeline: read here on every redraw, it was a JPEG decoded on
            // the main thread for every row with each progress update.
            if let url = downloads.imageURL(record.id) {
                RemoteImage(url: url)
            } else {
                Theme.surface
            }
        }
        .frame(width: episode ? 128 : (item?.isPlayableAudio == true ? 88 : 72), height: episode ? 72 : (item?.isPlayableAudio == true ? 88 : 108))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private var status: some View {
        switch record.state {
        case .downloading:
            let fraction = downloads.progress(record.id) ?? 0
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                Text(downloads.waitingForWiFi(record.id)
                     ? String(localized: "Waiting for Wi-Fi")
                     : record.bytesExpected > 0
                     ? String(localized: "\(ByteCountFormatter.string(fromByteCount: record.bytesWritten, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: record.bytesExpected, countStyle: .file))", comment: "Download progress, like 1.2 GB of 4.5 GB")
                     : String(localized: "Starting…", comment: "A download that hasn't begun to arrive"))
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .done:
            Text([ByteCountFormatter.string(fromByteCount: max(record.bytesExpected, record.bytesWritten), countStyle: .file),
                  downloads.quality(record.id)?.label].compactMap { $0 }.joined(separator: " · "))
                .font(.app(14))
                .foregroundStyle(Theme.textSecondary)
        case .failed:
            Text("Didn't finish. Tap to try again.")
                .font(.app(14, .semibold))
                .foregroundStyle(Theme.palette[1].1)
        }
    }
}

/// How many of a show's next episodes to keep on the device: none, or one of
/// the choices. Its label is the caller's.
struct KeepDownloadedMenu<Label: View>: View {
    @Environment(\.appState) private var app
    @ObservedObject private var smart = SmartDownloads.shared
    let seriesId: String
    let name: String
    @ViewBuilder let label: Label

    var body: some View {
        Menu {
            Picker(String(localized: "Keep Downloaded", comment: "A show's setting: its next episodes kept on the device"),
                   selection: Binding(get: { smart.keeps(seriesId) ?? 0 }, set: choose)) {
                Text(String(localized: "Off", comment: "Subtitles turned off")).tag(0)
                ForEach(SmartDownloads.choices, id: \.self) { Text(SmartDownloads.label($0)).tag($0) }
            }
        } label: {
            label
        }
        .accessibilityLabel(String(localized: "Keep Downloaded", comment: "A show's setting: its next episodes kept on the device"))
    }

    private func choose(_ count: Int) {
        guard let client = app?.client as? MediaBrowserClient else { return }
        smart.keep(seriesId: seriesId, name: name, count: count == 0 ? nil : count, client: client)
    }
}

/// A show page's button for it: filled while the show is kept downloaded.
struct KeepDownloadedButton: View {
    @ObservedObject private var smart = SmartDownloads.shared
    let series: BaseItem

    var body: some View {
        let on = smart.keeps(series.id) != nil
        KeepDownloadedMenu(seriesId: series.id, name: series.displayTitle) {
            Image(systemName: on ? "arrow.down.circle.fill" : "arrow.down.circle.dotted")
        }
        .buttonStyle(.action(active: on))
    }
}

/// The film page's download button: download, a ring while it comes down (tap
/// to stop), a filled arrow once it's here (tap to remove).
struct DownloadButton: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var downloads = Downloads.shared
    let item: BaseItem
    @State private var problem: String?
    @State private var confirmingRemove = false

    var body: some View {
        Button(action: tapped) {
            DownloadGlyph(id: item.id, size: 20)
        }
        .buttonStyle(.action(active: downloads.fileURL(item.id) != nil))
        .accessibilityLabel(label)
        .confirmationDialog(String(localized: "Remove the download?"), isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button(String(localized: "Remove Download"), role: .destructive) { downloads.remove(item.id) }
        }
        .alert(problem ?? "", isPresented: $problem.isPresent()) {}
    }

    private var label: String {
        switch downloads.record(item.id)?.state {
        case .downloading: String(localized: "Cancel Download")
        case .done: String(localized: "Remove Download")
        default: String(localized: "Download")
        }
    }

    private func tapped() {
        switch downloads.record(item.id)?.state {
        case .downloading:
            Task { await downloads.cancel(item.id) }
        case .done:
            confirmingRemove = true
        default:
            guard let client = app.client as? MediaBrowserClient else { return }
            let target = item
            Task { problem = await downloads.download(target, client: client) }
        }
    }
}

/// A download's state as an icon: an arrow to start, a filling ring while it
/// comes down, a filled arrow once it's here.
struct DownloadGlyph: View {
    @ObservedObject private var downloads = Downloads.shared
    let id: String
    var size: CGFloat = 18

    var body: some View {
        switch downloads.record(id)?.state {
        case .downloading:
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(downloads.progress(id) ?? 0, 0.02))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill").font(.system(size: size * 0.4, weight: .bold))
            }
            .frame(width: size, height: size)
        case .done:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: size, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: size, weight: .semibold))
        case nil:
            Image(systemName: "arrow.down.circle").font(.system(size: size, weight: .semibold))
        }
    }
}

/// On an episode card: nothing, or the download's state once there is one.
struct DownloadBadge: View {
    @ObservedObject private var downloads = Downloads.shared
    let id: String

    var body: some View {
        if downloads.record(id) != nil {
            DownloadGlyph(id: id, size: 22)
                .foregroundStyle(.white)
                .padding(6)
                .background(.black.opacity(0.55), in: Circle())
                .padding(8)
        }
    }
}

/// An album's, a playlist's or a book's download button: an arrow to start,
/// a filling ring while it comes down (tap to stop), a filled arrow once it's
/// all here (tap to remove), a warning when some of it didn't come (tap to try
/// again).
struct DownloadGroupButton: View {
    @EnvironmentObject var app: AppState
    @ObservedObject private var downloads = Downloads.shared
    let id: String
    let kind: DownloadGroup.Kind
    let name: String
    var byLine: String? = nil
    let pageId: String
    let items: [BaseItem]
    /// Whose cover it's kept with.
    let art: BaseItem?
    @State private var problem: String?
    @State private var confirmingRemove = false

    var body: some View {
        let state = downloads.groupState(id)
        Button(action: tapped) {
            DownloadGroupGlyph(state: state, size: 20)
        }
        .buttonStyle(.action(active: state == .done))
        .disabled(items.isEmpty)
        .accessibilityLabel(label(state))
        .confirmationDialog(String(localized: "Remove the download?"), isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button(String(localized: "Remove Download"), role: .destructive) { Task { await downloads.remove(group: id) } }
        } message: {
            Text("It stays on your server; only the copy on this device goes.")
        }
        .alert(problem ?? "", isPresented: $problem.isPresent()) {}
    }

    private func label(_ state: Downloads.GroupState) -> String {
        switch state {
        case .downloading: String(localized: "Cancel Download")
        case .done: String(localized: "Remove Download")
        default: String(localized: "Download")
        }
    }

    private func tapped() {
        guard let client = app.client as? MediaBrowserClient else { return }
        switch downloads.groupState(id) {
        case .downloading:
            Task { await downloads.remove(group: id) }
        case .done:
            confirmingRemove = true
        case .failed:
            Task { problem = await downloads.retry(group: id, client: client) }
        case .none:
            let (id, kind, name, byLine, pageId, items, art) = (id, kind, name, byLine, pageId, items, art)
            Task {
                problem = await downloads.download(group: id, kind: kind, name: name, byLine: byLine, pageId: pageId,
                                                   items: items, art: art, client: client)
            }
        }
    }
}

/// An album's, playlist's or book's download as an icon.
struct DownloadGroupGlyph: View {
    let state: Downloads.GroupState
    var size: CGFloat = 18

    var body: some View {
        switch state {
        case .downloading(let fraction):
            ZStack {
                Circle().stroke(.white.opacity(0.25), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: max(fraction, 0.02))
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Image(systemName: "stop.fill").font(.system(size: size * 0.4, weight: .bold))
            }
            .frame(width: size, height: size)
        case .done:
            Image(systemName: "arrow.down.circle.fill").font(.system(size: size, weight: .semibold))
        case .failed:
            Image(systemName: "exclamationmark.arrow.circlepath").font(.system(size: size, weight: .semibold))
        case .none:
            Image(systemName: "arrow.down.circle").font(.system(size: size, weight: .semibold))
        }
    }
}

/// An album, a playlist or a book on the Downloads page: its cover, its name,
/// how much of it is here; played from the device with a tap.
private struct DownloadGroupRow: View {
    @ObservedObject private var downloads = Downloads.shared
    let group: DownloadGroup
    let play: () -> Void
    let retry: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        let state = downloads.groupState(group.id)
        let counts = downloads.groupCounts(group.id)
        HStack(spacing: 16) {
            Button {
                switch state {
                case .done: play()
                case .failed: retry()
                default: if counts.done > 0 { play() }
                }
            } label: {
                HStack(spacing: 16) {
                    // Without a cover: a book or a note, not a film's strip.
                    RemoteImage(url: downloads.imageURL(group.id) ?? group.itemIds.lazy.compactMap({ downloads.imageURL($0) }).first,
                                symbol: group.kind == .book ? "books.vertical" : "music.note")
                    .frame(width: 88, height: 88)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(kindLabel)
                            .font(.app(14, .semibold))
                            .foregroundStyle(Theme.primary.1)
                            .lineLimit(1)
                        Text(group.name)
                            .font(.app(19, .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        status(state, counts: counts)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                if case .downloading = state {
                    Task { await downloads.remove(group: group.id) }
                } else {
                    confirmingRemove = true
                }
            } label: {
                Image(systemName: { if case .downloading = state { return "xmark.circle" } else { return "trash" } }())
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel({ if case .downloading = state { return String(localized: "Cancel Download") } else { return String(localized: "Remove Download") } }())
        }
        .padding(12)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .confirmationDialog(String(localized: "Remove the download?"), isPresented: $confirmingRemove,
                            titleVisibility: .visible) {
            Button(String(localized: "Remove Download"), role: .destructive) { Task { await downloads.remove(group: group.id) } }
        } message: {
            Text("It stays on your server; only the copy on this device goes.")
        }
    }

    private var kindLabel: String {
        let kind = switch group.kind {
        case .album: String(localized: "Album")
        case .playlist: String(localized: "Playlist")
        case .book: String(localized: "Audiobook")
        }
        return [kind, group.byLine].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func status(_ state: Downloads.GroupState, counts: (done: Int, total: Int)) -> some View {
        switch state {
        case .downloading(let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                    .tint(Theme.accent)
                Text(String(localized: "\(String(counts.done)) of \(String(counts.total))", comment: "Download progress, like 1.2 GB of 4.5 GB"))
                    .font(.app(14))
                    .foregroundStyle(Theme.textSecondary)
            }
        case .done, .none:
            Text(ByteCountFormatter.string(fromByteCount: downloads.groupBytes(group.id), countStyle: .file))
                .font(.app(14))
                .foregroundStyle(Theme.textSecondary)
        case .failed:
            Text("Didn't finish. Tap to try again.")
                .font(.app(14, .semibold))
                .foregroundStyle(Theme.palette[1].1)
        }
    }
}
#endif
