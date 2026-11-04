import AVKit
import CoreMedia

/// Switches the TV to the video's frame rate and dynamic range, when the viewer has
/// Match Content turned on, for every way the app plays a film or episode. AVPlayerViewController
/// only does this when the stream describes itself up front, which the remuxed HLS
/// streams the app plays don't, and VLC never does, so the app sets it from the
/// file's own metadata before playback starts. Live TV is left in the TV's own mode
/// (see `LiveTuner`).
#if os(tvOS)
@MainActor
enum DisplayCriteria {
    /// Asks for the file's mode. Returns whether a switch was requested.
    @discardableResult
    static func request(for source: MediaSource?) -> Bool {
        guard let manager, manager.isDisplayCriteriaMatchingEnabled,
              let video = source?.mediaStreams?.first(where: { $0.type == "Video" }),
              let rate = video.realFrameRate ?? video.averageFrameRate, rate > 0 else { return false }
        let range = keepsHDR(video) ? "HDR10" : video.videoRangeType ?? "SDR"
        guard let criteria = criteria(rate: rate, range: range, width: video.width, height: video.height) else { return false }
        // The TV is already there, as it is from one episode to the next:
        // nothing will switch, so there's nothing to wait for.
        let mode = "\(rate)|\(range)"
        if mode == current, manager.preferredDisplayCriteria != nil { return false }
        manager.preferredDisplayCriteria = criteria
        current = mode
        return true
    }

    /// Video that isn't HDR, asked for as HDR10 at its own rate where the
    /// viewer would have it brighter (`PlaybackPreferences.sdrInHDR`). Not on
    /// a television that can't show HDR at all.
    static func keepsHDR(_ video: MediaStream?) -> Bool {
        guard PlaybackPreferences.sdrInHDR, AVPlayer.eligibleForHDRPlayback, let video else { return false }
        return !isHDR(video.videoRangeType)
    }

    static func keepsHDR(for source: MediaSource?) -> Bool {
        keepsHDR(source?.mediaStreams?.first { $0.type == "Video" })
    }

    private static func isHDR(_ range: String?) -> Bool {
        guard let range else { return false }
        return range.hasPrefix("DOVI") || range.hasPrefix("HDR10") || range == "HLG"
    }

    /// The frame rate and range last asked for, while it's still in force.
    private static var current: String?

    /// Waits for the TV to finish switching (the screen goes blank meanwhile), so
    /// the start of the video isn't played to a dark screen.
    static func waitForSwitch(timeout: Duration = .seconds(6)) async {
        guard let manager else { return }
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        // The switch is reported a beat after the request.
        try? await Task.sleep(for: .milliseconds(300))
        while manager.isDisplayModeSwitchInProgress, clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Something else (AetherEngine) is setting the mode, so what was last
    /// asked for here no longer says what the TV is in: the next request is
    /// made whatever it is.
    static func forget() {
        current = nil
    }

    /// Back to the viewer's normal mode. Not done when playback ends: handing the
    /// mode back makes the TV renegotiate HDMI, and for two seconds the screen is
    /// black — so leaving a film showed a blank screen instead of the app. The
    /// mode is held until the app is left, where a blank is expected anyway, and
    /// the next film sets its own.
    static func reset() {
        current = nil
        manager?.preferredDisplayCriteria = nil
    }

    /// What the television was asked for, for the stats panel: the refresh
    /// rate, or that tvOS has matching turned off, which is why a television
    /// stays in the mode it was in.
    static var summary: String? {
        guard let manager else { return nil }
        guard manager.isDisplayCriteriaMatchingEnabled else {
            return String(localized: "Match Content is off", comment: "Stats panel: tvOS's Match Content setting is disabled, so the TV doesn't switch mode for the film")
        }
        // What the app last asked for, which it keeps a note of: the system
        // doesn't say back. Nothing when AetherEngine did the asking.
        guard let parts = current?.split(separator: "|"), let rate = parts.first.flatMap({ Double($0) }), rate > 0 else { return nil }
        let text = rate == rate.rounded() ? "\(Int(rate))" : String(format: "%.3f", rate)
        // And the range, where it isn't SDR: a film kept in HDR says so.
        guard parts.count > 1, isHDR(String(parts[1])) else { return text + " Hz" }
        let range = parts[1].hasPrefix("DOVI") ? "Dolby Vision" : parts[1] == "HLG" ? "HLG" : "HDR"
        return text + " Hz · " + range
    }

    private static var manager: AVDisplayManager? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .avDisplayManager
    }

    private static func criteria(rate: Double, range: String, width: Int?, height: Int?) -> AVDisplayCriteria? {

        var codec = kCMVideoCodecType_HEVC
        let transfer: CFString
        let wideGamut: Bool
        if range.hasPrefix("DOVI") {
            codec = kCMVideoCodecType_DolbyVisionHEVC
            transfer = range == "DOVIWithHLG" ? kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
                                              : kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            wideGamut = true
        } else if range == "HLG" {
            transfer = kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            wideGamut = true
        } else if range.hasPrefix("HDR10") {
            transfer = kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            wideGamut = true
        } else {
            transfer = kCMFormatDescriptionTransferFunction_ITU_R_709_2
            wideGamut = false
        }
        let extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_TransferFunction: transfer,
            kCMFormatDescriptionExtension_ColorPrimaries: wideGamut ? kCMFormatDescriptionColorPrimaries_ITU_R_2020
                                                                   : kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: wideGamut ? kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
                                                                : kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2,
        ]
        var description: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec,
                                       width: Int32(width ?? 3840), height: Int32(height ?? 2160),
                                       extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        guard let description else { return nil }
        return AVDisplayCriteria(refreshRate: Float(rate), formatDescription: description)
    }
}
#else
/// An iPad's screen has one mode and no television to switch, so there is
/// nothing to ask for and nothing to wait on.
@MainActor
enum DisplayCriteria {
    @discardableResult
    static func request(for source: MediaSource?) -> Bool { false }
    static func keepsHDR(_ video: MediaStream?) -> Bool { false }
    static func keepsHDR(for source: MediaSource?) -> Bool { false }
    static var summary: String? { nil }
    static func waitForSwitch(timeout: Duration = .seconds(6)) async {}
    static func forget() {}
    static func reset() {}
}
#endif
