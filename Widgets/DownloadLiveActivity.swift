import ActivityKit
import SwiftUI
import WidgetKit

/// Downloads coming down: on the Lock Screen, what's coming down now, how
/// far, and how many more; in the Dynamic Island, the same in brief.
struct DownloadLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: DownloadActivityAttributes.self) { context in
            LockScreenDownload(state: context.state)
                .padding(16)
                .activityBackgroundTint(WidgetColours.background.opacity(0.85))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                        .font(.title2)
                        .foregroundStyle(WidgetColours.gradient)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(DownloadWords.percent(state))
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                }
                DynamicIslandExpandedRegion(.center) {
                    Text(state.title)
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .lineLimit(1)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: state.fraction)
                            .tint(WidgetColours.blue)
                        Text(DownloadWords.status(state))
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                    .foregroundStyle(WidgetColours.blue)
            } compactTrailing: {
                Text(DownloadWords.percent(state))
                    .font(.system(.caption, design: .rounded).weight(.semibold))
                    .monospacedDigit()
            } minimal: {
                ProgressView(value: state.fraction)
                    .progressViewStyle(.circular)
                    .tint(WidgetColours.blue)
            }
        }
    }
}

private struct LockScreenDownload: View {
    let state: DownloadActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: state.finished ? "checkmark.circle.fill" : "arrow.down.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(WidgetColours.gradient)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(state.finished ? String(localized: "Downloaded", comment: "Live Activity: every download has finished")
                                        : String(localized: "Downloading", comment: "Live Activity: downloads are coming down"))
                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                        .kerning(1)
                        .textCase(.uppercase)
                        .foregroundStyle(.white.opacity(0.7))
                    Spacer()
                    Text(DownloadWords.percent(state))
                        .font(.system(.subheadline, design: .rounded).weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                }
                Text(state.title)
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                ProgressView(value: state.fraction)
                    .tint(WidgetColours.blue)
                Text(DownloadWords.status(state))
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }
}

enum DownloadWords {
    static func percent(_ state: DownloadActivityAttributes.ContentState) -> String {
        state.fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    /// "Waiting for Wi-Fi", "2 more after this one", "Ready to watch".
    static func status(_ state: DownloadActivityAttributes.ContentState) -> String {
        if state.finished { return String(localized: "Ready to watch, without your server.", comment: "Live Activity: downloads finished") }
        if state.waitingForWiFi { return String(localized: "Waiting for Wi-Fi") }
        let more = state.remaining - 1
        return more > 0 ? String(localized: "\(more) more after this one", comment: "Live Activity: how many downloads are waiting behind the one coming down")
                        : String(localized: "The last one", comment: "Live Activity: the download coming down is the only one left")
    }
}
