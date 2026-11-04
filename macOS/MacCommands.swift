#if os(macOS)
import SwiftUI

/// The Mac's menu bar: one window (File has no New Window), Settings… on ⌘, opening the
/// app's own Settings page, Go, with a key for each main section, as the Mac's TV app
/// has, and Controls for what's playing: a film when one is up, else music or a book.
struct MacCommands: Commands {
    let app: AppState
    @ObservedObject private var stage = MacPlayerStage.shared
    @ObservedObject private var music = MusicPlayer.shared

    var body: some Commands {
        CommandGroup(replacing: .newItem) {}
        CommandGroup(replacing: .appSettings) {
            Button(String(localized: "Settings…", comment: "Mac menu bar: opens the app's settings")) { app.askForSection("settings") }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu(String(localized: "Go", comment: "Mac menu bar: the menu of the app's sections")) {
            Button(String(localized: "Home", comment: "Menu section: the home screen")) { app.askForSection("home") }
                .keyboardShortcut("1")
            Button(String(localized: "Libraries")) { app.askForSection("libraries") }
                .keyboardShortcut("2")
            Button(String(localized: "Live TV", comment: "Menu section: the server's television channels")) { app.askForSection("livetv") }
                .keyboardShortcut("3")
            Divider()
            Button(String(localized: "Search", comment: "Menu section: the search screen")) { app.askForSection("search") }
                .keyboardShortcut("f")
        }
        CommandMenu(String(localized: "Controls", comment: "Mac menu bar: the menu of playback controls (play, pause, skip)")) {
            // Space does the same in the player; it isn't the menu's key, which would
            // take every space typed in a search.
            Button(playing ? String(localized: "Pause") : String(localized: "Play")) {
                if stage.showing { NotificationCenter.default.post(name: MacPlayerStage.playPauseAsked, object: nil) }
                else { music.togglePause() }
            }
            .disabled(!stage.showing && !music.isActive)
            Divider()
            if stage.showing {
                Button(String(localized: "Forward 10 seconds", comment: "Player button")) { skip(10) }
                    .keyboardShortcut(.rightArrow)
                Button(String(localized: "Back 10 seconds", comment: "Player button")) { skip(-10) }
                    .keyboardShortcut(.leftArrow)
            } else if music.isBook {
                Button(String(localized: "Forward 30 Seconds", comment: "Audiobook: on half a minute")) { music.skip(by: 30) }
                    .keyboardShortcut(.rightArrow)
                Button(String(localized: "Back 15 Seconds", comment: "Audiobook: back a quarter of a minute")) { music.skip(by: -15) }
                    .keyboardShortcut(.leftArrow)
            } else {
                Button(String(localized: "Next Song", comment: "Mac menu bar, Controls menu: to the song after the one playing")) { music.next() }
                    .keyboardShortcut(.rightArrow)
                    .disabled(!music.isActive)
                Button(String(localized: "Previous Song", comment: "Mac menu bar, Controls menu: to the song before the one playing, or the start of this one")) { music.previous() }
                    .keyboardShortcut(.leftArrow)
                    .disabled(!music.isActive)
            }
        }
    }

    private var playing: Bool { stage.showing ? stage.filmPlaying : music.isPlaying }

    private func skip(_ seconds: Int32) {
        NotificationCenter.default.post(name: MacPlayerStage.skipAsked, object: seconds)
    }
}
#endif
