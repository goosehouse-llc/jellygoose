import SwiftUI

/// One line of the stats panel: what it's about, and what's so.
struct StatLine: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
}

/// What a player can say about how the film is going, read afresh while the
/// panel is up. Each player fills in what it can measure and leaves the rest:
/// nothing here is worked out or guessed.
struct LiveStats: Equatable {
    /// The player's own name for what's decoding the picture.
    var decoder: String?
    /// The range the picture is going out in: "Dolby Vision", "HDR10", "SDR".
    var output: String?
    /// How the sound is going out, where the player says.
    var sound: String?
    /// Bits a second of what's playing now.
    var bitrate: Double?
    /// Bits a second the link delivers, while it's delivering.
    var throughput: Double?
    /// Seconds of film held ahead of the picture.
    var buffered: Double?
    var droppedFrames: Int?
    /// Times the picture has had to stop and wait for more.
    var stalls: Int?
    /// Frames a second being shown.
    var frameRate: Double?
    /// The picture as it's being played, which for a conversion isn't the
    /// file's own size.
    var size: CGSize?
}

/// The panel of facts about what's playing and how: which player, whether the
/// server is converting anything and why, what the file is, and how the
/// stream is holding up. For telling a film that's playing as it should from
/// one that only looks it.
enum PlaybackStats {
    /// On for as long as the app is open once it's turned on, so it carries
    /// from one episode to the next. Off again at the next launch.
    @MainActor static var shown = false

    static func lines(context: PlaybackContext, live: LiveStats, transcoding: TranscodingInfo?,
                      audioTrack: String?, subtitleTrack: String?, server: String?, display: String?) -> [StatLine] {
        let source = context.item.mediaSources?.first { $0.id == context.mediaSourceId } ?? context.item.mediaSources?.first
        let streams = context.mediaStreams.isEmpty ? (source?.mediaStreams ?? []) : context.mediaStreams
        let video = streams.first { $0.type == "Video" }
        // The sound that's on, by the name the menu has for it; else the one
        // the stream was asked for, else the file's first.
        let audio = streams.first { $0.type == "Audio" && audioTrack != nil && $0.trackName == audioTrack }
            ?? streams.first { $0.type == "Audio" && $0.index == context.audioIndex }
            ?? streams.first { $0.type == "Audio" && $0.isDefault == true }
            ?? streams.first { $0.type == "Audio" }
        // The file as it is unless Apple's player is being sent something else.
        let converted = context.engine == .avPlayer && !context.isDirect
        var lines: [StatLine] = []

        let player: String = switch context.engine {
        case .aether: "AetherEngine"
        case .vlc: "VLC"
        case .avPlayer: "AVPlayer"
        }
        lines.append(StatLine(id: "player", label: String(localized: "Player", comment: "Stats panel: which video player is playing the film"),
                              value: joined([player, live.decoder])))

        lines.append(StatLine(id: "playback", label: String(localized: "Playback"), value: method(converted: converted, transcoding)))
        if converted {
            let reasons = reasons(transcoding?.reasons.isEmpty == false ? transcoding?.reasons ?? [] : reasons(in: context.url),
                                  source: source, video: video, audio: audio)
            if !reasons.isEmpty {
                lines.append(StatLine(id: "reason", label: String(localized: "Reason", comment: "Stats panel: why the server is converting the film"),
                                      value: reasons))
            }
            if let sent = sent(transcoding, live: live) {
                lines.append(StatLine(id: "sent", label: String(localized: "Sent as", comment: "Stats panel: what the server is converting the film into"),
                                      value: sent))
            }
        }

        if let video {
            let rate = video.realFrameRate ?? video.averageFrameRate
            lines.append(StatLine(id: "video", label: String(localized: "Video", comment: "Stats panel: the film's picture"), value: joined([
                video.codec.map { MediaSummary.videoCodec($0) + ((video.bitDepth ?? 8) > 8 ? " \(video.bitDepth!)-bit" : "") },
                size(video.width, video.height),
                rate.map { fps($0) },
                MediaSummary.hdr(video.videoRangeType) ?? (video.videoRangeType == nil ? nil : "SDR"),
                video.bitRate.map { mbps(Double($0)) },
            ])))
        }
        if audioTrack != nil || audio != nil {
            lines.append(StatLine(id: "audio", label: String(localized: "Audio", comment: "Heading over the list of audio tracks"), value: joined([
                audioTrack ?? audio?.trackName,
                audio?.bitRate.map { mbps(Double($0)) },
                live.sound,
            ])))
        }
        if let subtitleTrack {
            lines.append(StatLine(id: "subtitles", label: String(localized: "Subtitles"), value: subtitleTrack))
        }
        if let source {
            lines.append(StatLine(id: "file", label: String(localized: "File", comment: "Stats panel: the film's file on the server"), value: joined([
                source.container.map(MediaSummary.container),
                source.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) },
                source.bitrate.flatMap { $0 > 0 ? mbps(Double($0)) : nil },
            ])))
        }

        let now = joined([
            live.bitrate.map(mbps),
            // As measured, which wanders: to a tenth, not the three places
            // a file's own rate is given to.
            live.frameRate.map { String(format: "%.1f fps", $0) },
            live.buffered.map { String(localized: "\(Int($0.rounded())) s buffered", comment: "Stats panel: seconds of film downloaded ahead of the picture; s abbreviates seconds") },
            live.droppedFrames.map { String(localized: "\($0) dropped", comment: "Stats panel: number of video frames the player has dropped") },
            live.stalls.flatMap { $0 > 0 ? String(localized: "\($0) stalls", comment: "Stats panel: times playback has stopped to wait for the network") : nil },
        ])
        if !now.isEmpty {
            lines.append(StatLine(id: "now", label: String(localized: "Now", comment: "Stats panel: live measurements of the stream"), value: now))
        }
        if let throughput = live.throughput {
            lines.append(StatLine(id: "network", label: String(localized: "Network"), value: mbps(throughput)))
        }
        let screen = joined([live.output, display])
        if !screen.isEmpty {
            lines.append(StatLine(id: "display", label: String(localized: "Display", comment: "Stats panel: what the television is being sent"), value: screen))
        }
        if let server, !server.isEmpty {
            lines.append(StatLine(id: "server", label: String(localized: "Server", comment: "Settings tile for the Jellyfin server this Apple TV is connected to"), value: server))
        }
        return lines
    }

    // MARK: How it's reaching the player

    static func method(converted: Bool, _ transcoding: TranscodingInfo?) -> String {
        guard converted else { return String(localized: "Direct play") }
        switch (transcoding?.isVideoDirect, transcoding?.isAudioDirect) {
        case (true?, true?):
            return String(localized: "Remuxed by the server", comment: "Stats panel: the server is repackaging the film without re-encoding picture or sound")
        case (true?, _):
            return String(localized: "Audio transcoded by the server", comment: "Stats panel: the server is re-encoding the sound and passing the picture through")
        case (false?, _):
            return String(localized: "Transcoded by the server", comment: "Stats panel: the server is re-encoding the picture")
        default:
            // Until the server has said which.
            return String(localized: "Converted by the server", comment: "Stats panel: the server is repackaging or re-encoding the film, not yet known which")
        }
    }

    /// The reasons a stream's own address carries, which is where the server
    /// puts them before its session says anything.
    private static func reasons(in url: URL) -> [String] {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name.caseInsensitiveCompare("TranscodeReasons") == .orderedSame }?.value?
            .split(separator: ",").map(String.init) ?? []
    }

    /// The server's reasons in a few words, with what in the file each is
    /// about: "MKV container · DTS audio".
    static func reasons(_ reasons: [String], source: MediaSource?, video: MediaStream?, audio: MediaStream?,
                        container: String? = nil) -> String {
        var said: [String] = []
        func say(_ words: String) { if !said.contains(words) { said.append(words) } }
        for reason in reasons {
            let reason = reason.lowercased()
            if reason.contains("subtitle") {
                say(String(localized: "Subtitles"))
            } else if reason.contains("bitrate") && !reason.hasPrefix("audio") {
                say(String(localized: "Quality limit", comment: "Stats panel: the film's bitrate is over the streaming quality cap set in Settings"))
            } else if reason.hasPrefix("container") {
                let name = (source?.container ?? container).map(MediaSummary.container) ?? ""
                say(String(localized: "\(name) container", comment: "Stats panel: the file's container format can't be played as it is. The placeholder is its name, like MKV"))
            } else if reason.hasPrefix("audio") || reason.hasPrefix("secondaryaudio") {
                let name = audio?.codec?.uppercased() ?? ""
                say(String(localized: "\(name) audio", comment: "Stats panel: the film's sound can't be played as it is. The placeholder is its codec, like DTS"))
            } else if reason.hasPrefix("video") || reason.hasPrefix("refframes") || reason.hasPrefix("anamorphic") || reason.hasPrefix("interlaced") {
                let name = video?.codec.map(MediaSummary.videoCodec) ?? ""
                say(String(localized: "\(name) video", comment: "Stats panel: the film's picture can't be played as it is. The placeholder is its codec, like AV1"))
            } else {
                say(reason)
            }
        }
        return said.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " · ")
    }

    /// What the server is making of it: only the halves that are new.
    private static func sent(_ transcoding: TranscodingInfo?, live: LiveStats) -> String? {
        guard let transcoding else {
            return live.size.map { size(Int($0.width), Int($0.height)) } ?? nil
        }
        var parts: [String?] = [transcoding.container?.uppercased()]
        if transcoding.isVideoDirect == false {
            parts.append(transcoding.videoCodec.map(MediaSummary.videoCodec))
            parts.append(size(transcoding.width, transcoding.height))
        }
        if transcoding.isAudioDirect == false, let codec = transcoding.audioCodec {
            parts.append(MediaSummary.audio(codec: codec, profile: nil, title: nil, channels: transcoding.audioChannels))
        }
        parts.append(transcoding.bitrate.flatMap { $0 > 0 ? mbps(Double($0)) : nil })
        if transcoding.isVideoDirect == false, let hardware = transcoding.hardwareAccelerationType,
           !hardware.isEmpty, hardware.lowercased() != "none" {
            parts.append(hardware)
        }
        let words = joined(parts)
        return words.isEmpty ? nil : words
    }

    // MARK: Words

    private static func joined(_ parts: [String?]) -> String {
        parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// "62 Mbps", "8.4 Mbps", "640 kbps".
    static func mbps(_ bitsPerSecond: Double) -> String {
        let mega = bitsPerSecond / 1_000_000
        if mega >= 10 { return "\(Int(mega.rounded())) Mbps" }
        if mega >= 1 { return String(format: "%.1f Mbps", mega) }
        return "\(Int((bitsPerSecond / 1000).rounded())) kbps"
    }

    private static func fps(_ rate: Double) -> String {
        let text = rate == rate.rounded() ? "\(Int(rate))" : String(format: "%.3f", rate)
        return text + " fps"
    }

    private static func size(_ width: Int?, _ height: Int?) -> String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }
}

/// The panel itself: labels down the left, what's so beside each, over the
/// picture's top corner where nothing else is.
struct StatsPanel: View {
    let lines: [StatLine]

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: CGFloat(18).scaled, verticalSpacing: CGFloat(7).scaled) {
            ForEach(lines) { line in
                GridRow {
                    Text(line.label.uppercased())
                        .font(.app(12, .heavy))
                        .kerning(1.2)
                        .foregroundStyle(Theme.palette[2].1)
                        .gridColumnAlignment(.leading)
                    Text(line.value)
                        .font(.app(16, .medium))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, CGFloat(20).scaled)
        .padding(.vertical, CGFloat(16).scaled)
        .frame(maxWidth: CGFloat(640).scaled, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.black.opacity(0.62))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 1)
                }
        }
        .accessibilityElement(children: .combine)
    }
}
