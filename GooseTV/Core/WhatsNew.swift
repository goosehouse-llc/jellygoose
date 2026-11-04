import Foundation

/// What a version brings, shown once to someone who updated to it: the first
/// time the app opens on a new version, over Home. Never on a first install,
/// where there's nothing to compare with. A version with no entry here shows
/// nothing, so a small fix doesn't interrupt anyone.
enum WhatsNew {
    struct Item: Identifiable {
        let icon: String
        let title: String
        let detail: String
        var id: String { title }
    }

    private static let seenKey = "whatsNew.seenVersion"

    /// The card's version: a fix release shows its version's card, and once
    /// only, whether or not the version before it was opened.
    static var version: String {
        let bundled = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let fixes = ["1.7.1": "1.7", "1.8.1": "1.8", "2.0.1": "2.0"]
        return fixes[bundled] ?? bundled
    }

    /// The highlights of this version, if it has any worth a screen.
    static var items: [Item] {
        switch version {
        case "1.2":
            var items: [Item] = []
            #if os(tvOS)
            items.append(Item(icon: "house.fill", title: String(localized: "A new Home", comment: "What's New: the Home screen was redesigned"),
                              detail: String(localized: "The highlighted title fills the screen, and the rows glide into place a press at a time.")))
            #endif
            items += [
                Item(icon: "square.grid.3x3.fill", title: String(localized: "Libraries, reworked", comment: "What's New: the library screens were redesigned"),
                     detail: String(localized: "Sort either way round, choose several genres or decades, and each library remembers how you left it.")),
                Item(icon: "bolt.fill", title: String(localized: "Quicker to start"),
                     detail: {
                         #if os(tvOS)
                         String(localized: "MKV films play straight from the file, keeping Dolby Vision and Atmos, and every film is set up while you read its page.")
                         #else
                         String(localized: "Films are set up while you read their page, so Play goes straight to playing.")
                         #endif
                     }()),
                Item(icon: "hifispeaker.2.fill", title: String(localized: "Lossless 7.1"),
                     detail: {
                         #if os(tvOS)
                         String(localized: "TrueHD and DTS now reach the Apple TV in full 7.1 instead of 5.1.")
                         #else
                         String(localized: "TrueHD and DTS now arrive in full 7.1 instead of 5.1.")
                         #endif
                     }()),
                Item(icon: "person.text.rectangle.fill", title: String(localized: "Cast biographies"),
                     detail: String(localized: "Select someone in the cast for their story, age and birthplace.")),
            ]
            return items
        case "1.3":
            return [
                Item(icon: "tray.and.arrow.down.fill",
                     title: String(localized: "Requests", comment: "Menu section and settings page: asking for titles through Seerr"),
                     detail: String(localized: "With Seerr beside your Jellyfin server, see what's trending and ask for films and shows from here.", comment: "What's New: the Requests section")),
                Item(icon: "forward.end.fill",
                     title: String(localized: "Intros and credits, skipped for you", comment: "What's New: automatic skipping"),
                     detail: String(localized: "Two switches in Settings, under Playback. Credits go straight on to the next episode.", comment: "What's New: automatic skipping")),
                Item(icon: "captions.bubble.fill",
                     title: String(localized: "Subtitles, found and styled", comment: "What's New: subtitle search and appearance"),
                     detail: String(localized: "Search the internet for subtitles from the player's Subtitles menu, and choose their colour, background and position in Settings.", comment: "What's New: subtitle search and appearance")),
                Item(icon: "bookmark.fill",
                     title: String(localized: "A watchlist", comment: "What's New: the film watchlist"),
                     detail: String(localized: "Mark films to watch later, from a film's page or a long press. Watching one takes it off.", comment: "What's New: the film watchlist")),
                Item(icon: "magnifyingglass",
                     title: String(localized: "Search goes further", comment: "What's New: wider search and more library kinds"),
                     detail: String(localized: "It finds people and collections too, and home videos and music videos are libraries now.", comment: "What's New: wider search and more library kinds")),
                Item(icon: "chart.bar.fill",
                     title: String(localized: "Stats while you watch", comment: "What's New: the playback stats panel"),
                     detail: String(localized: "A panel in the player shows which player has the film, and whether your server is converting it.", comment: "What's New: the playback stats panel")),
            ]
        case "1.4":
            var items = [
                Item(icon: "antenna.radiowaves.left.and.right",
                     title: String(localized: "Live TV", comment: "Menu section: the server's television channels"),
                     detail: String(localized: "Where your server has a tuner, its channels are here: a guide to browse, with the channel you're watching playing beside it.", comment: "What's New: the Live TV section")),
                Item(icon: "record.circle",
                     title: String(localized: "Recordings", comment: "What's New: recording from the Live TV guide"),
                     detail: String(localized: "Set a showing or a whole series to record from the guide, and see what's coming under Scheduled.", comment: "What's New: recording from the Live TV guide")),
                Item(icon: "tv",
                     title: String(localized: "On Now", comment: "Home row: what's on the television channels at this moment"),
                     detail: String(localized: "What's on your channels this minute, in a row on Home.", comment: "What's New: the On Now row on Home")),
                Item(icon: "rectangle.grid.1x2.fill",
                     title: String(localized: "Home, your way", comment: "What's New: Home's rows can be reordered and hidden"),
                     detail: String(localized: "Put Home's rows in the order you like, or switch one off: Settings, Home Screen.", comment: "What's New: Home's rows can be reordered and hidden")),
            ]
            #if os(iOS)
            items.append(Item(icon: "pip.enter",
                              title: String(localized: "Picture in Picture", comment: "Player button: shrinks the film to the system's small floating window"),
                              detail: String(localized: "Shrink a film to a small window and keep browsing. Turn the device on its side to fill the screen again.", comment: "What's New: Picture in Picture for films")))
            #endif
            return items
        case "1.5":
            var items = [
                Item(icon: "gobackward.10",
                     title: String(localized: "Pause and Rewind", comment: "Settings, Live TV: the switch for keeping the channel being watched on the device, so it can be paused and gone back through"),
                     detail: {
                         #if os(tvOS)
                         String(localized: "Left and right go back and on through the channel you're watching, and Play/Pause holds it. Up to half an hour is kept, on this Apple TV.", comment: "What's New: pausing and rewinding a television channel, with the Apple TV's remote")
                         #else
                         String(localized: "Hold a channel, or go back through it, with the buttons over the picture. Up to half an hour is kept, on this device.", comment: "What's New: pausing and rewinding a television channel, by touch")
                         #endif
                     }()),
                Item(icon: "captions.bubble",
                     title: String(localized: "Captions", comment: "Live TV: the words of what's said, sent with a broadcast, shown over the picture"),
                     detail: {
                         #if os(tvOS)
                         String(localized: "Press Up while a channel fills the screen for its captions, and for Audio Sync where the sound is out of step with your loudspeaker.", comment: "What's New: a channel's captions and the sound's timing, with the Apple TV's remote")
                         #else
                         String(localized: "The captions button over the picture shows a channel's captions.", comment: "What's New: a channel's captions, by touch")
                         #endif
                     }()),
            ]
            #if os(tvOS)
            items.append(Item(icon: "info.circle",
                              title: String(localized: "What's On", comment: "What's New: the card describing the programme a channel is showing"),
                              detail: String(localized: "Press Down while a channel fills the screen for a card of what's on: the programme, its episode and what follows. With the card up, left and right change channel.", comment: "What's New: the card describing the programme a channel is showing")))
            #endif
            items += [
                Item(icon: "record.circle",
                     title: String(localized: "Record Any Show", comment: "What's New: a series recording can be set for any programme"),
                     detail: String(localized: "Record Series is offered for every programme, not only numbered episodes: the evening news, every night. A long press on an On Now card offers it too.", comment: "What's New: a series recording can be set for any programme")),
                Item(icon: "list.bullet.rectangle",
                     title: String(localized: "Episodes in the Guide", comment: "What's New: the guide's squares name the episode"),
                     detail: String(localized: "The guide names the episode in each square, and leads with it on a channel that shows one series all day.", comment: "What's New: the guide's squares name the episode")),
            ]
            return items
        case "1.6":
            var items: [Item] = []
            #if os(tvOS)
            items += [
                Item(icon: "rectangle.split.2x2",
                     title: String(localized: "Multiview", comment: "Live TV: several channels on the screen at once, the sound from the one that's highlighted"),
                     detail: String(localized: "Up to four channels at once. Press Up while a channel fills the screen and choose Multiview; the sound follows the highlight.", comment: "What's New: Multiview, on the Apple TV")),
                Item(icon: "person.crop.circle",
                     title: String(localized: "A Profile for Everyone", comment: "What's New: the app follows whoever is chosen as the Apple TV's user"),
                     detail: String(localized: "JellyGoose follows whoever is chosen on the Apple TV, each with their own sign-in, Continue Watching and settings.", comment: "What's New: the app follows whoever is chosen as the Apple TV's user")),
            ]
            #else
            items.append(Item(icon: "car.fill",
                              title: "CarPlay",
                              detail: String(localized: "Browse your library and Live TV on the car's screen. The picture shows when the car is parked; while driving, you hear it.", comment: "What's New: CarPlay, on the iPhone")))
            #endif
            items += [
                Item(icon: "person.2.fill",
                     title: String(localized: "Watch Together", comment: "Menu section and player menu: watching the same film in step with other people, each on their own device (Jellyfin's SyncPlay)"),
                     detail: String(localized: "Start a group or join one from the menu, then play something: it plays for everyone in step, each on their own screen.", comment: "What's New: Watch Together")),
                Item(icon: "backward.end.fill",
                     title: String(localized: "Watch from the Start", comment: "Live TV: shows a programme that's being recorded as it's broadcast from its beginning"),
                     detail: String(localized: "Tuned in late? A programme your server is recording can be watched from its beginning while it's still on.", comment: "What's New: watching a recording in progress from its start")),
                Item(icon: "forward.fill",
                     title: String(localized: "Skip Commercials", comment: "Button over a recording: jumps past a commercial break the server has marked"),
                     detail: String(localized: "Where your server marks the breaks in a recording, they're drawn on the timeline and a press skips each one.", comment: "What's New: skipping marked commercials in recordings")),
                Item(icon: "moon.zzz.fill",
                     title: String(localized: "Sleep Timer", comment: "Player menu: stops playback after a while, or when what's playing ends"),
                     detail: String(localized: "Stop after a while, or when the film, episode or programme ends: from the player's buttons, or Live TV's.", comment: "What's New: the sleep timer")),
            ]
            return items
        case "1.7":
            var items: [Item] = []
            #if os(tvOS)
            items += [
                Item(icon: "appletv.fill",
                     title: String(localized: "Play on TV", comment: "Title of the list of TVs a film can be played on from the phone, and the button that opens it"),
                     detail: String(localized: "Send a film here from Jellyfin's web app, on a phone or a computer, and control it from there. Name this Apple TV in Settings, Playback.", comment: "What's New: Play on TV, on the Apple TV")),
                Item(icon: "sun.max.fill",
                     title: String(localized: "SDR video in HDR", comment: "Setting: keep the TV in HDR for films and episodes that aren't HDR"),
                     detail: String(localized: "Keep the TV in HDR for everything, for a brighter picture on TVs whose HDR runs brighter. In Settings, Playback.", comment: "What's New: the setting that keeps standard-range video in HDR")),
            ]
            #else
            items += [
                Item(icon: "appletv.fill",
                     title: String(localized: "Play on TV", comment: "Title of the list of TVs a film can be played on from the phone, and the button that opens it"),
                     detail: String(localized: "Play a film on an Apple TV with JellyGoose open, from its page here, and use this as the remote.", comment: "What's New: Play on TV, on the iPhone and iPad")),
                Item(icon: "car.fill",
                     title: "CarPlay",
                     detail: String(localized: "Choose on your car's screen and hear it as you drive. In a car that shows video, watch it there while you're parked.", comment: "What's New: CarPlay, on the iPhone")),
            ]
            #endif
            items += [
                Item(icon: "forward.end.fill",
                     title: String(localized: "Skip Recaps and Previews", comment: "What's New: skipping an episode's previously-on recap and its look at the next episode"),
                     detail: String(localized: "Skip an episode's \"previously on\" and its look at the next one, where your server marks them, or have them skipped for you.", comment: "What's New: skipping recaps and previews")),
                Item(icon: "film.fill",
                     title: String(localized: "Trailers and Theme Music", comment: "What's New: a trailer button and theme songs on title pages"),
                     detail: String(localized: "A Trailer button on a film's page, and a show's theme song played quietly on its page where your server has one.", comment: "What's New: trailers and theme music")),
                Item(icon: "record.circle",
                     title: String(localized: "Recordings"),
                     detail: String(localized: "Each recording on its own card, with the day it aired and the programme's picture, and new ones there as soon as you look.", comment: "What's New: the recordings library's changes")),
            ]
            return items
        case "1.8":
            let music = Item(icon: "music.note",
                             title: String(localized: "Music", comment: "Eyebrow above a music library's name"),
                             detail: {
                                 #if os(tvOS)
                                 String(localized: "Your server's albums, artists and playlists, with lyrics and Up Next. The music plays on while you browse.", comment: "What's New: music libraries, on the Apple TV")
                                 #else
                                 String(localized: "Your server's albums, artists and playlists, with lyrics and Up Next, playing on in the background and in the car with CarPlay.", comment: "What's New: music libraries, on the iPhone and iPad")
                                 #endif
                             }())
            let books = Item(icon: "book.fill",
                             title: String(localized: "Audiobooks", comment: "Eyebrow above a library of books, and Home's row of them"),
                             detail: String(localized: "Books from your server, chapter by chapter, at the speed you like, and picked up where you left off.", comment: "What's New: audiobooks"))
            let sync = Item(icon: "icloud.fill",
                            title: String(localized: "iCloud Sync", comment: "Settings tile and page: settings shared between devices through iCloud"),
                            detail: String(localized: "Settings, pinned views and each show's choices go with you to your other devices through iCloud.", comment: "What's New: settings shared through iCloud"))
            #if os(tvOS)
            return [
                music,
                books,
                Item(icon: "text.badge.plus",
                     title: String(localized: "Playlists and Collections", comment: "What's New: video playlists and adding to collections"),
                     detail: String(localized: "Make playlists of films and episodes from their long-press menu, and add films and shows to collections where your account may.", comment: "What's New: video playlists and adding to collections")),
                Item(icon: "captions.bubble.fill",
                     title: String(localized: "Audio and Subtitles, Show by Show", comment: "What's New: the tracks chosen in an episode are used for the rest of the show"),
                     detail: String(localized: "Choose an episode's audio or subtitles once, and the show's other episodes use them too.", comment: "What's New: the tracks chosen in an episode are used for the rest of the show")),
                sync,
                Item(icon: "puzzlepiece.extension.fill",
                     title: String(localized: "Plugins", comment: "Settings tile and page: the server's plugins"),
                     detail: String(localized: "Server administrators can add, update, switch off and remove the server's plugins in Settings.", comment: "What's New: managing the server's plugins")),
            ]
            #else
            return [
                music,
                books,
                Item(icon: "mic.fill",
                     title: String(localized: "Siri and Shortcuts", comment: "What's New: actions for Siri and the Shortcuts app"),
                     detail: String(localized: "Pick up where you left off, play a film or a show, or shuffle your music, from Siri or the Shortcuts app.", comment: "What's New: actions for Siri and the Shortcuts app")),
                Item(icon: "square.grid.2x2.fill",
                     title: String(localized: "Widgets", comment: "What's New: widgets for the Home Screen and Lock Screen"),
                     detail: String(localized: "Continue Watching and Next Up on your Home Screen and Lock Screen, and a download's progress there as it comes in.", comment: "What's New: widgets and the downloads Live Activity")),
                Item(icon: "arrow.down.circle.fill",
                     title: String(localized: "Keep Downloaded", comment: "A show's setting: its next episodes kept on the device"),
                     detail: String(localized: "Set it on a show and its next episodes download by themselves, then go once they're watched.", comment: "What's New: a show's next episodes kept on the device")),
                sync,
            ]
            #endif
        case "2.0":
            let mac = Item(icon: "macbook",
                           title: String(localized: "Now on Mac", comment: "What's New: JellyGoose is on the Mac"),
                           detail: String(localized: "JellyGoose for Mac: your library in a window of its own, with downloads, Live TV and music. Your unlock covers it.", comment: "What's New: the Mac app"))
            let dashboard = Item(icon: "gauge.with.dots.needle.67percent",
                                 title: String(localized: "Dashboard", comment: "Settings tile and page: what the server is doing, for its administrators"),
                                 detail: String(localized: "Server administrators can see who's watching and how, send a message or stop playback, and run the server's tasks, in Settings.", comment: "What's New: the server dashboard"))
            #if os(tvOS)
            return [
                mac,
                dashboard,
                Item(icon: "record.circle",
                     title: String(localized: "Recordings in Top Shelf", comment: "What's New: recordings have pictures in the Apple TV's Top Shelf"),
                     detail: String(localized: "Recordings in Continue Watching on the Apple TV's Home Screen show their pictures.", comment: "What's New: recordings' pictures in the Top Shelf")),
            ]
            #else
            var items: [Item] = []
            #if os(iOS)
            items.append(mac)
            #endif
            items += [
                Item(icon: "music.note.list",
                     title: String(localized: "Music and Audiobooks to Go", comment: "What's New: albums, playlists and audiobooks can be downloaded"),
                     detail: String(localized: "Download albums, playlists and audiobooks, and listen with no server in reach.", comment: "What's New: music and audiobooks downloaded")),
                Item(icon: "arrow.down.circle.fill",
                     title: String(localized: "Download Quality", comment: "Downloads page: how big downloaded films and episodes are"),
                     detail: String(localized: "Have your server make a smaller copy as it downloads, so a whole season fits.", comment: "What's New: smaller downloads")),
                Item(icon: "bell.badge.fill",
                     title: String(localized: "New Episode Alerts", comment: "What's New: notifications of new episodes"),
                     detail: String(localized: "A notification when a new episode of a show you watch arrives. Turn it on in Settings, Playback.", comment: "What's New: new-episode alerts")),
                dashboard,
            ]
            return items
            #endif
        default:
            return []
        }
    }

    /// Whether to show it now. `returning` is whether the viewer was already
    /// signed in when the app opened, which a fresh install never is; a fresh
    /// install is marked as having seen this version.
    static func isDue(returning: Bool) -> Bool {
        let defaults = UserDefaults.standard
        let seen = defaults.string(forKey: seenKey)
        guard seen != version else { return false }
        guard returning else {
            defaults.set(version, forKey: seenKey)
            return false
        }
        if items.isEmpty {
            defaults.set(version, forKey: seenKey)
            return false
        }
        return true
    }

    static func markSeen() {
        UserDefaults.standard.set(version, forKey: seenKey)
    }
}
