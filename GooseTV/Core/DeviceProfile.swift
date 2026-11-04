import Foundation

/// Capability profile sent to Jellyfin so it can decide between
/// direct play, direct stream (remux), or transcoding.
/// Apple TV 4K handles H.264/HEVC natively; anything else falls back to HLS transcode.
enum DeviceProfile {
    static let appleTV: [String: Any] = [
        "Name": "JellyGoose (Apple TV)",
        "MaxStreamingBitrate": 120_000_000,
        "MaxStaticBitrate": 120_000_000,
        "DirectPlayProfiles": [
            [
                "Type": "Video",
                "Container": "mp4,m4v,mov",
                "VideoCodec": "h264,hevc,dvhe,dvh1",
                "AudioCodec": "aac,ac3,eac3,alac,flac",
            ],
            [
                "Type": "Audio",
                "Container": "mp3,aac,m4a,m4b,flac,alac,wav",
            ],
        ],
        "TranscodingProfiles": [
            [
                "Type": "Video",
                "Container": "mp4",
                "Protocol": "hls",
                "VideoCodec": "hevc,h264",
                // Sound the Apple TV can't decode (TrueHD, DTS) is converted to
                // FLAC, which it plays up to 7.1 and loses nothing. Jellyfin caps
                // AAC and Dolby Digital at 5.1 when it converts, so with AAC first
                // a 7.1 track lost its side or rear pair. AAC, AC-3 and E-AC-3
                // sources are still passed through as they are.
                "AudioCodec": "flac,aac,ac3,eac3",
                "Context": "Streaming",
                "MaxAudioChannels": "8",
                "MinSegments": 2,
                "BreakOnNonKeyFrames": true,
            ],
        ],
        "SubtitleProfiles": [
            ["Format": "vtt", "Method": "Hls"],
            ["Format": "vtt", "Method": "External"],
        ],
        "CodecProfiles": [],
        "ContainerProfiles": [],
    ]

    /// The Apple TV's profile with no way to show a subtitle beside the picture,
    /// so the server burns the one asked for into it: for the car, where the
    /// picture is all that's shown.
    static var burningSubtitles: [String: Any] {
        var profile = appleTV
        profile["Name"] = "JellyGoose (CarPlay)"
        profile["SubtitleProfiles"] = [[String: Any]]()
        return profile
    }

    /// A television channel in the car: H.264 with stereo AAC over HLS, what
    /// any car's AirPlay takes, at a rate a phone's connection carries. What
    /// a station sends (MPEG-2 and Dolby Digital over the air) is converted.
    static let carLive: [String: Any] = [
        "Name": "JellyGoose (CarPlay Live TV)",
        "MaxStreamingBitrate": 4_000_000,
        "MaxStaticBitrate": 4_000_000,
        "DirectPlayProfiles": [[String: Any]](),
        "TranscodingProfiles": [
            [
                "Type": "Video",
                "Container": "ts",
                "Protocol": "hls",
                "VideoCodec": "h264",
                "AudioCodec": "aac",
                "Context": "Streaming",
                "MaxAudioChannels": "2",
                "MinSegments": 2,
                "BreakOnNonKeyFrames": true,
            ],
        ],
        "SubtitleProfiles": [[String: Any]](),
        "CodecProfiles": [[String: Any]](),
        "ContainerProfiles": [[String: Any]](),
    ]

    /// For VLC, which plays nearly anything: direct-play every container and codec
    /// (a profile with no lists matches all), subtitles left in the file for VLC to draw.
    static let vlc: [String: Any] = [
        "Name": "JellyGoose (VLC)",
        "MaxStreamingBitrate": 120_000_000,
        "MaxStaticBitrate": 120_000_000,
        "DirectPlayProfiles": [
            ["Type": "Video"],
            ["Type": "Audio"],
        ],
        "TranscodingProfiles": appleTV["TranscodingProfiles"] ?? [],
        // Inside the file, read from it; or beside it, fetched as a file of
        // its own, which is what both players do with those. Without the
        // second, a film whose account would have a subtitle file on was
        // refused whole ("SubtitleCodecNotSupported"): the file can't travel
        // inside the film, so the server offered a conversion instead and the
        // film went to Apple's player by way of one.
        "SubtitleProfiles": ["srt", "subrip", "ass", "ssa", "vtt", "webvtt", "pgssub", "dvdsub", "dvbsub", "mov_text"]
            .map { ["Format": $0, "Method": "Embed"] }
            + ["srt", "subrip", "ass", "ssa", "vtt", "webvtt"].map { ["Format": $0, "Method": "External"] },
        "CodecProfiles": [],
        "ContainerProfiles": [],
    ]
}
