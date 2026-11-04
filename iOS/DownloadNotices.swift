import OSLog
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif
import UserNotifications

/// Tells the viewer when a download is ready to watch, or didn't make it,
/// wherever they are: a banner from the system, with the title's picture.
/// Choosing it opens the title's page.
@MainActor
final class DownloadNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = DownloadNotices()

    /// Asked the first time a download starts, not at launch: that's when
    /// the question makes sense to someone.
    func askLeave() async {
        #if os(macOS) && DEBUG
        // Not in a script's test run on the developer's Mac: the question
        // waits on their screen, and the download with it.
        if ProcessInfo.processInfo.environment["GOOSETV_MAC_SNAP"] != nil { return }
        #endif
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func finished(_ item: BaseItem, picture: URL?) {
        post(for: item, title: String(localized: "Ready to watch", comment: "Notification title: a download has finished"),
             body: String(localized: "\(name(of: item)) has downloaded", comment: "Notification body; the placeholder is a film or episode"),
             picture: picture)
    }

    /// An album, a playlist or an audiobook has all come down.
    func finished(name: String, pageId: String, picture: URL?) {
        post(id: pageId, title: String(localized: "Ready to listen", comment: "Notification title: an album, playlist or audiobook has downloaded"),
             body: String(localized: "\(name) has downloaded", comment: "Notification body; the placeholder is a film or episode"),
             picture: picture)
    }

    func failed(_ item: BaseItem) {
        post(for: item, title: String(localized: "Download failed", comment: "Notification title"),
             body: String(localized: "\(name(of: item)) couldn't be downloaded. Open JellyGoose to try again.",
                          comment: "Notification body; the placeholder is a film or episode"),
             picture: nil)
    }

    /// "Bluey · S2 · E9 · Bingo", or a film's title.
    private func name(of item: BaseItem) -> String {
        guard item.isEpisode else { return item.displayTitle }
        return [item.seriesName, item.episodeLabel, item.name].compactMap { $0 }.joined(separator: " · ")
    }

    private func post(for item: BaseItem, title: String, body: String, picture: URL?) {
        post(id: item.id, title: title, body: body, picture: picture)
    }

    private func post(id: String, title: String, body: String, picture: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.threadIdentifier = "downloads"
        content.userInfo = ["itemId": id]
        // The system takes the attachment's file for itself, so it gets a copy.
        if let picture, FileManager.default.fileExists(atPath: picture.path) {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("notice-\(id).jpg")
            try? FileManager.default.removeItem(at: copy)
            if (try? FileManager.default.copyItem(at: picture, to: copy)) != nil,
               let attachment = try? UNNotificationAttachment(identifier: "picture", url: copy) {
                content.attachments = [attachment]
            }
        }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "download-\(id)", content: content, trigger: nil)) { error in
            if let error { Self.log.error("notice for \(id, privacy: .public) not posted: \(error, privacy: .public)") }
        }
    }

    private static let log = Logger(subsystem: "com.goosehouse.jellygoose", category: "downloads")

    // MARK: Delegate

    /// Shown even while the app is open: someone browsing elsewhere in it
    /// still wants to know.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    /// Chosen: the title's page, through the app's own link.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["itemId"] as? String
        Task { @MainActor in
            if let id, let url = URL(string: "jellygoose://item/\(id)") {
                await UIApplication.shared.open(url)
            }
            completionHandler()
        }
    }
}
