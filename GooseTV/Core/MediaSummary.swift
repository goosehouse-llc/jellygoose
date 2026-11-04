import Foundation

/// Short, human labels for what's in a file: "4K", "Dolby Vision", "HEVC 10-bit",
/// "TrueHD 7.1 Atmos", "MKV", "24 Mbps". Shown on detail pages.
struct MediaSummary {
    let resolution: String?
    /// The HDR format, kept apart so it can be highlighted.
    let hdr: String?
    /// Codecs, container, bitrate.
    let details: [String]

    init?(_ source: MediaSource?) {
        guard let source, let streams = source.mediaStreams else { return nil }
        let video = streams.first { $0.type == "Video" }
        let audio = streams.first { $0.type == "Audio" && $0.isDefault == true }
            ?? streams.first { $0.type == "Audio" }

        var labels: [String] = []
        resolution = video.flatMap(Self.resolution)
        if let video {
            hdr = Self.hdr(video.videoRangeType)
            if let codec = video.codec {
                let depth = (video.bitDepth ?? 8) > 8 ? " \(video.bitDepth!)-bit" : ""
                labels.append(Self.videoCodec(codec) + depth)
            }
        } else {
            hdr = nil
        }
        if let audio, let codec = audio.codec {
            labels.append(Self.audio(codec: codec, profile: audio.profile, title: audio.displayTitle,
                                     channels: audio.channels))
        }
        if let container = source.container { labels.append(Self.container(container)) }
        if let bitrate = source.bitrate, bitrate > 0 {
            let mbps = Double(bitrate) / 1_000_000
            labels.append(mbps >= 10 ? "\(Int(mbps.rounded())) Mbps" : String(format: "%.1f Mbps", mbps))
        }
        details = labels
        if resolution == nil && hdr == nil && labels.isEmpty { return nil }
    }

    private static func resolution(_ video: MediaStream) -> String? {
        let width = video.width ?? 0, height = video.height ?? 0
        guard width > 0 || height > 0 else { return nil }
        // Width first: widescreen films are short for their class (a 4K scope film is ~1600 high).
        if width >= 3200 || height >= 2000 { return "4K" }
        if width >= 1800 || height >= 1000 { return "1080p" }
        if width >= 1200 || height >= 700 { return "720p" }
        return "SD"
    }

    static func hdr(_ rangeType: String?) -> String? {
        guard let rangeType else { return nil }
        if rangeType.hasPrefix("DOVI") { return "Dolby Vision" }
        switch rangeType {
        case "HDR10Plus": return "HDR10+"
        case "HDR10": return "HDR10"
        case "HLG": return "HLG"
        default: return nil
        }
    }

    static func videoCodec(_ codec: String) -> String {
        switch codec.lowercased() {
        case "h264", "avc": return "H.264"
        case "hevc", "h265": return "HEVC"
        case "av1": return "AV1"
        case "vp9": return "VP9"
        case "vp8": return "VP8"
        case "mpeg2video": return "MPEG-2"
        case "mpeg4", "msmpeg4v3", "xvid", "divx": return "MPEG-4"
        case "vc1": return "VC-1"
        default: return codec.uppercased()
        }
    }

    static func audio(codec: String, profile: String?, title: String?, channels: Int?) -> String {
        let name: String
        switch codec.lowercased() {
        case "aac": name = "AAC"
        case "ac3": name = "Dolby Digital"
        case "eac3": name = "Dolby Digital+"
        case "truehd": name = "TrueHD"
        case "dts":
            let profile = profile ?? ""
            name = profile.contains("MA") ? "DTS-HD MA" : profile.contains("HRA") ? "DTS-HD HRA"
                : profile.contains("X") ? "DTS:X" : "DTS"
        case "flac": name = "FLAC"
        case "opus": name = "Opus"
        case "vorbis": name = "Vorbis"
        case "mp3": name = "MP3"
        case "alac": name = "ALAC"
        case let pcm where pcm.hasPrefix("pcm"): name = "PCM"
        default: name = codec.uppercased()
        }
        var label = name
        switch channels {
        case 1: label += " " + String(localized: "Mono", comment: "Audio with one channel")
        case 2: label += " " + String(localized: "Stereo", comment: "Audio with two channels")
        case 6: label += " 5.1"
        case 8: label += " 7.1"
        case let n?: label += " \(n)ch"
        case nil: break
        }
        let hints = [profile, title].compactMap { $0 }.joined(separator: " ")
        if hints.localizedCaseInsensitiveContains("atmos") { label += " Atmos" }
        return label
    }

    static func container(_ container: String) -> String {
        // Jellyfin can report a family ("mov,mp4,m4a,…"); the first entry names it.
        let first = container.split(separator: ",").first.map(String.init)?.lowercased() ?? container
        switch first {
        case "matroska", "mkv": return "MKV"
        case "mov", "mp4", "m4v": return first == "mov" && !container.contains("mp4") ? "MOV" : "MP4"
        case "mpegts", "ts", "m2ts": return "TS"
        default: return first.uppercased()
        }
    }
}
