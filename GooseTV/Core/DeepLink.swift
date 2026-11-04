import Foundation

/// How the Top Shelf hands an item back to the app.
///
/// The extension can't play anything or show a page; selecting a tile launches
/// the app with one of these URLs, and the app decides what that means. Shared
/// by both targets so the two halves can't drift apart.
enum DeepLink {
    static let scheme = "jellygoose"

    /// What was chosen on the shelf.
    struct Opened: Equatable {
        let itemId: String
        /// Play pressed on the remote, rather than select.
        let play: Bool
    }

    /// Select: open the item's page.
    static func display(_ itemId: String) -> URL { url(host: "item", itemId) }

    /// Play: start it, from where it was left.
    static func play(_ itemId: String) -> URL { url(host: "play", itemId) }

    static func parse(_ url: URL) -> Opened? {
        guard url.scheme == scheme else { return nil }
        let id = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !id.isEmpty else { return nil }
        switch url.host {
        case "item": return Opened(itemId: id, play: false)
        case "play": return Opened(itemId: id, play: true)
        default: return nil
        }
    }

    // A fixed scheme and an id the server generated: there is no string here that
    // can fail to parse, and TVTopShelfAction won't take an optional.
    private static func url(host: String, _ itemId: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.path = "/" + itemId
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }
}
