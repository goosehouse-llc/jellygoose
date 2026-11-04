# JellyGoose 1.8 — App Store copy (iPhone and iPad)

For the iPhone and iPad's 1.8 (build 103), alongside the Apple TV's. 1.7.1
(build 102) was the first iPhone release, so this is the first iOS version
with a What's New. Keywords stay as they are live.

Screenshots: 1.7's, with music third in each set in place of the asking
panel (08): `final-ios/iphone-11-music.png` (Now Playing with the lyrics up
at the chorus) and `final-ios/ipad-11-music.png` (Now Playing with the cover:
the iPad's lyrics view leaves the cover out). The album is made up (Juniper
Gale, "Northbound": `AppStore/music/`) and on the throwaway server;
`StoreShotsiOSUITests.test11Music` takes them, given MUSIC_ALBUM and
JG_SERVER/JG_USER/JG_PASS. The iPad's comes out on its side and is turned
with `Tools/upright.swift`.

## What's New — 1544 / 4000

```
• Music: your server's albums, artists, songs and playlists, with lyrics, Up Next, shuffle, repeat and Instant Mix, playing on in the background, from the Lock Screen and in CarPlay. Make playlists, star favourites and browse by genre
• Audiobooks: chapter by chapter, at the speed you like, and picked up where you left off
• Siri and Shortcuts: "Continue watching in JellyGoose", play a film or show by name, or shuffle your music
• Widgets: Continue Watching and Next Up on the Home Screen and Lock Screen, and a Live Activity that follows your downloads
• Spotlight: your films and shows in the iPhone's and iPad's search
• Keep Downloaded: a show's next episodes download by themselves and go once they're watched. Download is in every film's and episode's long-press menu too
• Your own tab bar on iPhone: up to four tabs of any section, library or pinned view. Settings, Tab Bar, or hold the bar
• Playlists of films and episodes, and adding to collections, from the long-press menu
• Coming Soon: a row on Home of the episodes still to air
• Audio and subtitles, show by show, and Dialogue Boost for films the built-in VLC engine plays
• Pinned views can be rows on Home, and iCloud Sync shares settings, pins and each show's choices with your other devices
• Plugins: server administrators can manage the server's plugins from Settings
• iPhone on its side: the menu sits beside the Dynamic Island, and pages no longer slide under it
• Ready for iPhone Duo: tabs beside the folded screen's camera, and the player shaped around the fold
```

The Siri phrases are English only (the Shortcuts actions' names are
translated). iPhone Duo was checked in the simulator only.

## Promotional text — 127 / 170

```
New in 1.8: music and audiobooks, in CarPlay too, plus Siri, widgets, Spotlight, and a show's next episodes downloaded for you.
```

## Description — 3972 / 4000

1.7.1's, with a Music and Audiobooks paragraph, Keep Downloaded under Take It
With You, Siri, widgets, Spotlight and each show's tracks under the little
things, and iCloud under Everyone Gets Their Own. Paid for with "Follow a face,
or a studio", "A pause or a skip is everyone's", the second never-re-encode
claim under Big Files, "coming soon" under Requests and a few shorter phrases.

```
JellyGoose is a player for the media server you already run. It finds your Jellyfin server on your network, you pick who's watching, and your films and shows are there: big, poster-forward and quick to move through.

A HOME THAT SHOWS YOU WHAT'S THERE
What you're part-way through leads the screen with its artwork and logo, ready to resume, with Continue Watching, Next Up and the newest in each library beneath it.

TAKE IT WITH YOU
Download a film, an episode or a whole season to your iPhone or iPad and watch it with no server in reach. Downloads wait for Wi-Fi unless you say otherwise, and where you got to is passed back to your server when you're home. Or have a show's next episodes download by themselves.

MUSIC AND AUDIOBOOKS
Your server's albums, artists and playlists, with lyrics, Up Next and Instant Mix, playing on in the background and in CarPlay. Audiobooks go chapter by chapter, at your speed, picking up where you stopped.

LIVE TV FROM YOUR OWN TUNER
Give your server a tuner, an HDHomeRun for one, and JellyGoose adds Live TV: a guide with your channel playing alongside, what's on now on Home, and recording of one showing or a whole series. Pause a channel or go back through it, turn on its captions, start a programme that's still recording from its beginning, skip the marked commercials in a recording, and find what's on from Search.

ASK FOR WHAT ISN'T THERE
Run Seerr beside your server and JellyGoose adds a Requests section: what's trending and popular. Ask for a film, a show or one season from wherever you are.

IT PLAYS WHAT THE SYSTEM PLAYER WON'T
H.264 and HEVC go to Apple's own player, where HDR and Dolby Vision belong. AV1, VP9, MPEG-2 and the rest go to a built-in VLC engine, played straight from the original file, so your server never has to re-encode anything.

BUILT FOR BIG FILES
4K remuxes start quickly and stay smooth: a film is made ready while you read its page. A Stats button shows which player has the film, and whether your server is converting anything and why.

PICTURE IN PICTURE, AND YOUR TV
Shrink a film to a corner of the screen and go on browsing. Or play it on an Apple TV running JellyGoose, with your phone as the remote.

WATCH TOGETHER
Start a group or join one, and a film plays for everyone at the same moment, each on their own screen.

LIBRARIES THAT KEEP UP
Move through thousands of titles, or jump to any letter. Sort seven ways, either way round. Choose several genres or decades at once, show only what you haven't watched, and each library remembers how you left it. Pin any view to the menu or to Home.

SUBTITLES THAT KEEP TIME
Pick a subtitle and it's there, on time, in any film. Choose its size, colour, background and height, or nudge its timing. When a film has none, search the internet from the player and it appears without the film restarting.

EVERYONE GETS THEIR OWN
Everyone who signs in gets a face on the sign-in screen: pick yours and you're in, with your own Continue Watching, watched marks, favourites and library settings, and iCloud carries your settings to your other devices.

THE LITTLE THINGS
Skip intros, recaps and credits, or have them skipped for you. Each show remembers its audio and subtitles. See the next episode coming as the credits roll. Preview frames while you scrub. Set a sleep timer. Watch a film's trailer. Keep a watchlist of films. Ask Siri to carry on, add widgets to your Home Screen, and find a film from Spotlight.

MAKE IT YOURS
Six colour schemes, one a true black for OLED, six app icons, and Home's rows in the order you choose. In nine languages.

NOTHING PHONES HOME
No accounts, no subscription, no analytics, no advertising, no third parties. JellyGoose talks to your own servers and nowhere else, apart from asking your own network where they are during setup.

Requires your own Jellyfin server. Free to try for 7 days, then one purchase unlocks it here and on Apple TV. Not affiliated with or endorsed by the Jellyfin project.
```

## Review notes — 3967 / 4000

1.7.1's, with a 1.8 section (music on the demo server, Siri, widgets,
Spotlight, Keep Downloaded, iCloud Sync, and Plugins said to be the server's
own, under Guideline 2.5.2), and the server-dependent features in one
sentence.

```
JellyGoose is a client for Jellyfin and Emby media servers. It has no accounts and no content of its own: it plays what is on a server the user runs, so a server is required to see anything. The Apple TV version is on the same App Store record.

For review, please use the Jellyfin project's public demo server:

1. Launch the app. On "Connect to your Jellyfin or Emby server", tap the address field and enter:
   demo.jellyfin.org
   (demo.jellyfin.org/stable and https://demo.jellyfin.org/stable work too.)
2. Tap Connect. The sign-in screen for "Stable Demo" appears. Enter user name "demo" and leave the password empty.
3. Tap Sign In. The home screen will show films, shows and music that can be browsed and played.

Free trial (Guideline 3.1.1): the app is free to download, and playing needs the free non-consumable "7-day Trial" or the non-consumable "JellyGoose Unlock". The first time anything is played, the unlock screen states the trial's length, that playing stops after it, and the unlock's price; tap Start Free Trial to go on. Browsing stays free. Restore Purchases is on that screen and in Settings > JellyGoose Unlock.

If the app says it couldn't reach a server, the address was not entered as above; the same server can be opened in a browser at https://demo.jellyfin.org/stable to confirm it is up.

New in 1.8, and what the demo server shows of it:

- Music: the demo server's Music library is in the menu, with albums, artists, songs and playlists. Music plays on in the background, with a mini player above the tabs, and in CarPlay's Music tab.
- Siri and Shortcuts: App Shortcuts such as "Continue watching in JellyGoose" and "Shuffle music in JellyGoose", and the same actions in the Shortcuts app.
- Widgets: Continue Watching and Next Up for the Home Screen and Lock Screen, and a Live Activity while downloads run. Spotlight indexes the library's films and shows on the device.
- Keep Downloaded, a show's setting in Downloads, downloads its next episodes by themselves.
- Audiobooks, Coming Soon and Add to Collection appear where a server has books, future episodes and collections the account may change; the demo server has none.
- iCloud Sync (Settings > iCloud Sync) shares the app's own settings between the user's devices through iCloud key-value storage, and can be turned off.
- Plugins (Settings > Plugins) lets the administrator of a Jellyfin server install, update, switch off and remove that server's plugins, from the catalogue the server itself offers, and restart it. The server downloads and runs them; the app downloads and runs no code (Guideline 2.5.2). Only administrators see it; the demo account is not one, so it is absent there, as is library management.

Downloads: a film's page has a download button, and the Downloads tab lists what is on the device. Picture in Picture: a button at the top of the player.

Watch Together works on the demo server: Watch Together > Start a Group in the menu, then play any film. Play on TV, under Play on a film's page, lists Apple TVs running JellyGoose on the same account; with none, the list says so.

CarPlay: the app holds the CarPlay Audio entitlement only. In every car it shows CarPlay's templates: Home, the libraries, Music, Search, and Live TV where the user's server has channels. In a car that supports video, a film plays with its picture while parked; otherwise, and while driving, as sound.

Earlier features that depend on the user's own server are absent on the demo server, as intended: Live TV (needs a tuner such as an HDHomeRun on the server, which tunes and records; the app has no channels of its own), Requests (a front end to the user's own Seerr), Search for Subtitles (through the server's own provider), and skipping marked intros, recaps and credits.

The app collects no data and contains no advertising or analytics. It communicates only with the servers the user chooses, and with the user's own iCloud for settings while iCloud Sync is on.
```
