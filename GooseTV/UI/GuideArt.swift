import SwiftUI

/// The guide's picture of a programme, for the recordings of it. The server
/// gives a recording no cover: at best a frame it took from the file, and
/// until it has, nothing. The listings have the programme's own picture for
/// as long as it's on in the days they cover, which for the news every night
/// is always; so a library of recordings asks the guide by name, the once.
@MainActor
final class GuideArt {
    /// What the guide had for each name asked: the programme, for its
    /// picture at whatever size is wanted.
    private var known: [String: BaseItem] = [:]
    /// When each name last found nothing. Asked again after a while: the
    /// guide lists a day ahead, and a programme gone from it (aired, and
    /// not on again within the day) may be back in it tomorrow.
    private var missed: [String: Date] = [:]
    private var asking: [String: Task<BaseItem?, Never>] = [:]
    /// Counts the accounts: an answer for the one before isn't kept.
    private var generation = 0

    /// The answer already had, for a card drawn again: no flash of the
    /// placeholder as cells are reused.
    func cached(_ name: String?) -> BaseItem? {
        name.flatMap { known[$0.lowercased()] }
    }

    func find(_ name: String?, with client: (any MediaServer)?) async -> BaseItem? {
        guard let name, !name.isEmpty, let client else { return nil }
        let key = name.lowercased()
        if let answer = known[key] { return answer }
        if let when = missed[key], Date().timeIntervalSince(when) < 600 { return nil }
        if let task = asking[key] { return await task.value }
        let task = Task { await client.guideProgramme(named: name) }
        asking[key] = task
        let mine = generation
        let answer = await task.value
        guard mine == generation, !task.isCancelled else { return nil }
        asking[key] = nil
        if let answer { known[key] = answer; missed[key] = nil } else { missed[key] = Date() }
        return answer
    }

    /// Another account or another server: its guide is another guide.
    func forget() {
        generation += 1
        asking.values.forEach { $0.cancel() }
        asking = [:]
        known = [:]
        missed = [:]
    }
}

/// The picture a recording's page is headed by, and its shape, width over
/// height.
struct RecordingCover: Equatable {
    let url: URL
    let shape: Double
    /// The show or film recorded, where the library has it: then `url` is
    /// its backdrop, shown as a film's is, and its logo heads the words.
    var title: BaseItem? = nil
}

private struct BorrowsGuideArtKey: EnvironmentKey {
    static let defaultValue: Bool? = nil
}

extension EnvironmentValues {
    /// Set over a library of recordings: its cards show the guide's picture
    /// of a programme that has no poster of its own.
    var borrowsGuideArt: Bool? {
        get { self[BorrowsGuideArtKey.self] }
        set { self[BorrowsGuideArtKey.self] = newValue }
    }
}

/// A recording's picture in a card the shape of a poster, found as its page
/// finds it (`AppState.recordingCover`): the library's own show, the
/// programme's picture kept beside the recording, the guide's; or else the
/// frame the server took.
struct RecordingArt: View {
    @Environment(\.appState) private var app
    let item: BaseItem
    /// The item's own picture, if it has any.
    let own: URL?
    @State private var cover: URL?

    init(item: BaseItem, own: URL?, known: URL?) {
        self.item = item
        self.own = own
        _cover = State(initialValue: known.map(Self.cardSized))
    }

    var body: some View {
        FittedArt(url: cover ?? own)
            .task(id: item.id) {
                guard cover == nil, let found = await app?.recordingCover(for: item)?.url else { return }
                cover = Self.cardSized(found)
            }
    }

    /// The cover asked for at a card's size, not its page's: a grid of
    /// pictures two thousand wide filled the memory kept for them twenty
    /// cards in.
    private static func cardSized(_ url: URL) -> URL {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = parts.queryItems?.map { $0.name == "maxWidth" ? URLQueryItem(name: "maxWidth", value: "640") : $0 }
        return parts.url ?? url
    }
}

/// A picture wider than the card it's in, shown whole: itself again behind,
/// blurred and dimmed, fills what it leaves of the card.
struct FittedArt: View {
    let url: URL?

    var body: some View {
        // Each laid out against the card and not against the other: beside
        // the one that overflows, the whole one was given its size too.
        Color.clear
            .overlay { RemoteImage(url: url).blur(radius: 20) }
            .clipped()
            .contentShape(.interaction, Rectangle())
            .overlay(Color.black.opacity(0.35))
            .overlay { RemoteImage(url: url, contentMode: .fit) }
    }
}
