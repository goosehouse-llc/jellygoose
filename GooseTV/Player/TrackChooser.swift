import SwiftUI

/// One selectable audio or subtitle track, as the chooser lists it.
struct PlayerTrack: Identifiable, Hashable {
    /// Whatever the engine needs to select it again, as a string: VLC's own
    /// numbering on one side, the server's on the other.
    let id: String
    let name: String
    /// The server's number for it, where the player knows it.
    var serverIndex: Int? = nil
}

/// Both lists, and what is playing now.
struct TrackList: Equatable {
    var audio: [PlayerTrack] = []
    var subtitles: [PlayerTrack] = []
    var currentAudio: String?
    var currentSubtitle: String?

    /// The id the subtitle list uses for "off". The server has no index for it
    /// and VLC calls it -1, so the chooser needs a spelling of its own.
    static let subtitlesOff = "off"
}

/// The player's tracks against the server's numbering of the film's streams,
/// both ways: for a remote's choice of track, and for telling the server
/// which are on so a remote can show it.
extension PlaybackContext {
    /// The player's own id for the stream the server numbers `index`: the
    /// one the player has numbered so, the server's number where the player
    /// goes by it, the file's own for the player that reads the file, and
    /// for VLC by order: it lists the file's tracks in the file's order,
    /// with the subtitle files beside the film after them. By name last.
    func trackId(forServerIndex index: Int, in tracks: [PlayerTrack], kind: String) -> String? {
        if let known = tracks.first(where: { $0.serverIndex == index }) { return known.id }
        if let exact = tracks.first(where: { $0.id == "s\(index)" }) { return exact.id }
        if engine == .aether, let number = mediaStreams.fileStream(forServerIndex: index),
           let inFile = tracks.first(where: { $0.id == "\(number)" }) {
            return inFile.id
        }
        if engine == .vlc, let place = inOrder(kind).firstIndex(where: { $0.index == index }) {
            let listed = listedInOrder(tracks)
            if listed.indices.contains(place) { return listed[place].id }
        }
        guard let stream = mediaStreams.first(where: { $0.index == index && $0.type == kind }) else { return nil }
        return tracks.first { $0.name == stream.trackName }?.id
    }

    /// The server's number for the player's track `id`; -1 for subtitles off.
    func serverIndex(forTrackId id: String?, in tracks: [PlayerTrack], kind: String) -> Int? {
        guard let id else { return nil }
        if id == TrackList.subtitlesOff { return PlaybackContext.subtitlesOff }
        if let known = tracks.first(where: { $0.id == id })?.serverIndex { return known }
        if id.hasPrefix("s"), let index = Int(id.dropFirst()) { return index }
        if engine == .aether, let number = Int(id), let stream = mediaStreams.stream(atFileStream: number), stream.type == kind {
            return stream.index
        }
        if engine == .vlc, let place = listedInOrder(tracks).firstIndex(where: { $0.id == id }) {
            let streams = inOrder(kind)
            if streams.indices.contains(place) { return streams[place].index }
        }
        guard let name = tracks.first(where: { $0.id == id })?.name else { return nil }
        return mediaStreams.first { $0.type == kind && $0.trackName == name }?.index
    }

    /// The streams of a kind in the order a player lists them: those inside
    /// the file, then the files beside it.
    private func inOrder(_ kind: String) -> [MediaStream] {
        let streams = mediaStreams.filter { $0.type == kind && $0.index != nil }.sorted { ($0.index ?? 0) < ($1.index ?? 0) }
        return streams.filter { $0.isExternal != true } + streams.filter { $0.isExternal == true }
    }

    /// The tracks the player found in the film itself: not "off", and not
    /// the subtitles the app draws, which go by the server's numbers.
    private func listedInOrder(_ tracks: [PlayerTrack]) -> [PlayerTrack] {
        tracks.filter { $0.id != TrackList.subtitlesOff && !$0.id.hasPrefix("s") }
    }
}

/// One column of a player panel: a ruled heading in the section's colour over a
/// list, on a surface of its own so the picture behind it doesn't read through
/// the words. No scroll view: one with nothing focusable in it makes itself
/// focusable on tvOS and takes focus from the picture, which is where every
/// press has to go. A long list is shown a window at a time instead.
struct PlayerPanelColumn<Top: View, Content: View>: View {
    let title: String
    let accent: (Color, Color)
    /// Rows above the heading, a list of their own: Live TV's Multiview
    /// over the captions.
    let top: Top
    let content: Content

    init(title: String, accent: (Color, Color), @ViewBuilder top: () -> Top, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accent = accent
        self.top = top()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if Top.self != EmptyView.self {
                VStack(alignment: .leading, spacing: 4) {
                    top
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
            HStack(spacing: 10) {
                Capsule().fill(accent.1).frame(width: 4, height: CGFloat(18).scaled)
                Text(title.uppercased())
                    .font(.app(13, .heavy))
                    .kerning(1.6)
                    .foregroundStyle(accent.1)
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 12)

            VStack(alignment: .leading, spacing: 4) {
                content
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .padding(.vertical, 20)
        .frame(minWidth: CGFloat(400).scaled, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.black.opacity(0.55))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
    }
}

extension PlayerPanelColumn where Top == EmptyView {
    init(title: String, accent: (Color, Color), @ViewBuilder content: () -> Content) {
        self.init(title: title, accent: accent, top: { EmptyView() }, content: content)
    }
}

/// A row in one of those columns: a tick where the chosen one is, so the list
/// reads down the left edge rather than by hunting for a highlighted pill.
struct PlayerPanelRow: View {
    let title: String
    /// A second, smaller line: what tells one subtitle found from another.
    var detail: String? = nil
    var trailing: String? = nil
    let chosen: Bool

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark")
                .font(.app(16, .bold))
                .opacity(chosen ? 1 : 0)
                .frame(width: CGFloat(22).scaled)
            VStack(alignment: .leading, spacing: 3) {
                // A found subtitle's name is the release it was timed to,
                // told from the next one by its last few words: two lines
                // where one won't hold it.
                Text(title)
                    .font(.app(20, chosen ? .bold : .medium))
                    .lineLimit(detail == nil ? 1 : 2)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.app(15, .medium))
                        .opacity(0.6)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 16)
            if let trailing {
                Text(trailing)
                    .font(.app(17, .medium))
                    .monospacedDigit()
                    .opacity(0.55)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }
}

/// The speeds either engine offers, the same list in both.
enum PlaybackSpeed {
    static let rates: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    /// "1.25×", in the viewer's own way of writing a decimal.
    static func label(_ rate: Float) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

/// How much earlier or later a subtitle the app draws is shown, for one timed
/// to a different cut of the film.
enum SubtitleTiming {
    static let steps: [Double] = [-3, -2, -1, -0.5, 0, 0.5, 1, 2, 3]

    static func label(_ step: Double) -> String {
        guard step != 0 else { return String(localized: "On Time", comment: "Subtitles shifted by nothing") }
        let amount = step.magnitude == step.magnitude.rounded() ? "\(Int(step.magnitude))" : "\(step.magnitude)"
        return step < 0 ? String(localized: "\(amount) s Earlier", comment: "Subtitles shifted earlier by a number of seconds; s abbreviates seconds") : String(localized: "\(amount) s Later", comment: "Subtitles shifted later by a number of seconds; s abbreviates seconds")
    }
}

/// How far each title's sound is moved against its picture, for a file whose
/// own is out: later is positive. Kept by the title (and shared through
/// iCloud), since it's the file that's off and not the room, and its next
/// episode may be fine.
enum AudioSync {
    static let key = "goosetv.audioSync"

    /// A tenth of a second later or earlier (`tenths` of 1 or -1), no
    /// further than the two seconds either way the players carry.
    static func nudged(_ seconds: Double, by tenths: Int) -> Double {
        Double(min(max(Int((seconds * 10).rounded()) + tenths, -20), 20)) / 10
    }

    static func offset(for itemId: String) -> Double {
        let saved = (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[itemId] ?? 0
        // To a step, so the one in force is the one ticked.
        return min(max((saved * 10).rounded() / 10, -2), 2)
    }

    static func set(_ seconds: Double, for itemId: String) {
        var saved = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        // Back in sync is kept as 0 rather than dropped, so another device's
        // older offset for it can't come back (see `SettingsSync`).
        saved[itemId] = seconds
        UserDefaults.standard.set(saved, forKey: key)
    }

    /// "In Sync", "0.6 s Later".
    static func label(_ seconds: Double) -> String {
        seconds == 0 ? String(localized: "In Sync", comment: "The sound isn't shifted against the picture")
                     : SubtitleTiming.label(seconds)
    }
}
