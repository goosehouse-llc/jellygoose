import Foundation
import VLCKitSPM

/// Dialogue Boost: what VLC can do to the sound it plays — Live TV, and
/// films VLC plays — with its equalizer. Apple's player and AetherEngine hand
/// the sound to the system as it comes, with nothing to work on it with, so
/// the films they play keep their sound as it is.
///
/// No Night Mode: VLC's compressor would be it, but VLCKit has no way to put
/// it in the sound (its equalizer call sets the player's filters to the
/// equalizer alone, and neither a stream's options nor the player's take
/// it). The Apple TV's own Reduce Loud Sounds, in its settings, does it for
/// everything.
@MainActor
final class AudioClarity: ObservableObject {
    static let shared = AudioClarity()
    static let dialogueKey = "goosetv.dialogueBoost"

    /// Voices brought forward: the rumble under them cut, their own band lifted.
    @Published var dialogueBoost = UserDefaults.standard.bool(forKey: AudioClarity.dialogueKey) {
        didSet {
            UserDefaults.standard.set(dialogueBoost, forKey: Self.dialogueKey)
            for player in players.allObjects { player.equalizer = Self.equalizer(dialogueBoost) }
        }
    }

    private let players = NSHashTable<VLCMediaPlayer>.weakObjects()

    /// A player to keep in step: its sound as it should be now, and whenever
    /// the boost changes.
    func attach(_ player: VLCMediaPlayer) {
        players.add(player)
        player.equalizer = Self.equalizer(dialogueBoost)
    }

    /// Speech sits between about 300 Hz and 4 kHz: the band below it (music's
    /// and explosions' weight) cut, the band itself lifted, the top left
    /// nearly as it is; and the whole brought down first, so the lift has
    /// room and doesn't clip.
    private static func equalizer(_ on: Bool) -> VLCAudioEqualizer? {
        guard on else { return nil }
        let equalizer = VLCAudioEqualizer()
        equalizer.preAmplification = -5
        for band in equalizer.bands {
            band.amplification = gain(at: band.frequency)
        }
        return equalizer
    }

    nonisolated static func gain(at frequency: Float) -> Float {
        switch frequency {
        case ..<100: return -10
        case ..<250: return -6
        case ..<450: return -1
        case ..<900: return 3
        case ..<1600: return 5
        case ..<4500: return 6
        case ..<7500: return 3
        case ..<13000: return 0
        default: return -2
        }
    }
}

/// How Dialogue Boost is named and described in the players.
enum AudioClarityText {
    static var dialogue: String { String(localized: "Dialogue Boost", comment: "Player sound setting: voices brought forward") }
    static var dialogueDetail: String {
        String(localized: "Voices brought forward, the rumble under them cut.", comment: "Under Dialogue Boost in the player")
    }
}
