# JellyGoose 2.0 — App Store copy
2.0 (build 107) on all three platforms, entered 2026-10-28 at Sam's word ("let's bump to 2.0 and submit all
platforms"): the Mac's first version (its 1.9 entry renamed), offline music and audiobooks, download
quality, the server dashboard and new-episode alerts. Each platform's text below is what App Store
Connect has, read back; all three release by hand (MANUAL). Keywords carried over. Header: the goose
before the violet play screen (asset 27400019…) on all three.

## Apple TV

### What's New — 430 / 4000

```
• JellyGoose is now on the Mac: your library in a window of its own, with downloads, Live TV and music. Your unlock covers it, as it does the iPhone and iPad
• Dashboard: server administrators can see who's watching what and how it reaches them, send a message or stop playback, run the server's scheduled tasks and read its activity, in Settings
• Recordings in Continue Watching on the Apple TV's Home Screen show their pictures
```

### Promotional text — 145 / 170

```
New in 2.0: JellyGoose on the Mac, and a dashboard for whoever runs the server: who's watching, how it reaches them, and what the server's doing.
```

### Description — 3972 / 4000

```
JellyGoose is a player for the media server you already run. It finds your Jellyfin server on your network, you pick who's watching, and your films and shows are there: big, poster-forward and quick to move through.

A HOME THAT SHOWS YOU WHAT'S THERE
Whatever you highlight fills the top of the screen with its artwork, logo, tagline and details, while Continue Watching, Next Up and the newest in each library glide into place beneath it.

IT PLAYS WHAT THE SYSTEM PLAYER WON'T
H.264 and HEVC go to Apple's own player, where HDR, Dolby Vision and frame-rate matching belong. AV1, VP9, MPEG-2 and the rest go to a built-in VLC engine, played straight from the original file, so your server never has to re-encode anything.

BUILT FOR BIG FILES
4K remuxes start quickly and stay smooth: a film is made ready while you read its page. TrueHD and DTS reach the Apple TV in full, lossless 7.1. A Stats button shows which player has the film, and whether your server is converting anything and why.

LIVE TV FROM YOUR OWN TUNER
Give your server a tuner, an HDHomeRun for one, and JellyGoose adds Live TV: a guide with your channel playing beside it, what's on now on Home, and recording of one showing or a whole series. Pause a channel or go back through it, and turn on its captions. Watch up to four channels at once with Multiview, start a programme that's still recording from its beginning, and skip the marked commercials in a recording.

MUSIC AND AUDIOBOOKS
Your server's albums, artists and playlists, with lyrics, Up Next and Instant Mix, playing on while you browse. Audiobooks go chapter by chapter, at your speed, picking up where you stopped.

WATCH TOGETHER, OR FROM YOUR PHONE
Start a group or join one, and a film plays for everyone at the same moment, each on their own screen. Or send a film to the Apple TV from Jellyfin on your phone, and pause it or change its subtitles from there.

ASK FOR WHAT ISN'T THERE
Run Seerr beside your server and JellyGoose adds a Requests section: what's trending and popular. Ask for a film, a show or one season from the sofa.

LIBRARIES THAT KEEP UP
Move through thousands of titles, or jump to any letter. Sort seven ways, either way round. Choose several genres or decades at once, show only what you haven't watched, and each library remembers how you left it. Pin any view to the menu or to Home, and make playlists of films and episodes.

SUBTITLES THAT KEEP TIME
Pick a subtitle and it's there, on time, in any film. Choose its size, colour, background and height, or nudge its timing. When a film has none, search the internet from the player and it appears without the film restarting.

EVERYONE GETS THEIR OWN
JellyGoose follows whoever is chosen on the Apple TV: their own sign-in, Continue Watching, watched marks, favourites and settings. Someone new picks their face once. Settings follow you to your other devices through iCloud.

THE LITTLE THINGS
Skip intros, recaps and credits, or have them skipped for you. See the next episode coming as the credits roll. Each show remembers its audio and subtitles. Preview frames while you scrub. Set a sleep timer. Change the speed, bring voices forward, or pull out-of-step sound back into time. Keep a watchlist of films. Watch a film's trailer, and hear a show's theme on its page.

FOR WHOEVER RUNS THE SERVER
See who's watching and how, send a message or stop playback, run the server's tasks, and manage its plugins.

MAKE IT YOURS
Six colour schemes, one a true black for OLED, six app icons, and Home's rows in the order you choose. In nine languages.

NOTHING PHONES HOME
No accounts, no subscription, no analytics, no advertising, no third parties. JellyGoose talks to your own servers and nowhere else, apart from asking your own network where they are during setup.

Requires your own Jellyfin server. Free to try for 7 days, then one purchase unlocks it here, on iPhone and iPad, and on the Mac. Not affiliated with or endorsed by the Jellyfin project.
```

### Review notes — 3841 / 4000

```
JellyGoose is a client for Jellyfin and Emby media servers. It has no accounts and no content of its own: it plays what is on a server the user runs, so a server is required to see anything.

For review, please use the Jellyfin project's public demo server:

1. Launch the app. On "Connect to your Jellyfin or Emby server", select the address field and enter:
   demo.jellyfin.org/stable
   No "https://" is needed; demo.jellyfin.org on its own also connects.
2. Press Connect. The sign-in screen for "Stable Demo" appears. Enter user name "demo" and leave the password empty.
3. Press Sign In. The home screen will show films, shows and music that can be browsed and played.

Free trial (Guideline 3.1.1): the app is free to download, and playing needs the free non-consumable "7-day Trial" or the non-consumable "JellyGoose Unlock", shared with the iPhone and iPad app. The first time anything is played, the unlock screen states the trial's length, that playing stops after it, and the unlock's price; select Start Free Trial to go on. Browsing stays free. Restore Purchases is on that screen and in Settings > JellyGoose Unlock.

If the app says it couldn't reach a server, the address was not entered as above; the same server can be opened in a browser at https://demo.jellyfin.org/stable to confirm it is up.

New in 2.0:

- Dashboard (Settings > Dashboard) is for a Jellyfin server's administrators: who is watching what and how (direct play or transcoding, with the server's reasons), Send Message and Stop Playback for a session, the server's scheduled tasks to run or stop, and its activity log. The demo account is not an administrator, so it is absent there, as are Plugins and library management.
- JellyGoose for Mac is new on this record; the trial and the unlock are shared with it.

From 1.8, on the demo server: Music (albums, artists, songs, playlists; it plays on while the app is used), and playlists of films and episodes (Add to Playlist… in a long-press menu). Audiobooks, Coming Soon and Add to Collection appear where a server has books, future episodes and collections. iCloud Sync shares the app's own settings through iCloud key-value storage and can be turned off. Plugins (Settings > Plugins, administrators only) asks the server to install, update or remove its own plugins; the server runs them and the app runs no code (Guideline 2.5.2).

Earlier features that depend on the user's own server, absent on the demo server as intended:

- Live TV (guide, recordings, Multiview, listings in Search) needs a television tuner on the user's server, such as an HDHomeRun; the server tunes and records, and the app has no channels of its own. Up to half an hour of a channel is kept in temporary files so it can be paused, deleted when the channel is left.
- Requests is a front end to Seerr (an open-source request manager) where the user's server has it; the app fetches no media itself.
- Search for Subtitles asks the user's server to search the subtitle provider its owner has set up, for accounts allowed to manage subtitles.
- Skip Intro, Recap, Preview and Credits, trailers and theme music act where a server marks or keeps them.

Also on the demo server: Watch Together (Watch Together > Start a Group in the menu, then play a film; it is Jellyfin's SyncPlay), and Play on TV: with JellyGoose open, sign in as demo at https://demo.jellyfin.org/stable in a browser, choose the cast button, pick the Apple TV (it can be named in Settings > Playback) and play a film; the browser's controls act on it. The app runs as the current Apple TV user (User Management capability), each with their own sign-in and settings.

The app collects no data and contains no advertising or analytics. It communicates only with the servers the user chooses, and with the user's own iCloud for settings while iCloud Sync is on.
```

## iPhone and iPad

### What's New — 646 / 4000

```
• JellyGoose is now on the Mac: your library in a window of its own, with downloads, Live TV and music. Your unlock covers it
• Music and audiobooks to go: download albums, playlists and audiobooks, and listen with no server in reach
• Download quality: have your server make a smaller copy as it downloads (1080p, 720p or 480p), subtitles and all, so a whole season fits
• New episode alerts: a notification when a new episode of a show you watch reaches your server. Turn it on in Settings, Playback
• Dashboard: server administrators can see who's watching and how, send a message or stop playback, run the server's tasks and read its activity
```

### Promotional text — 133 / 170

```
New in 2.0: JellyGoose on the Mac, music and audiobooks to go, smaller downloads, and alerts for new episodes of the shows you watch.
```

### Description — 3979 / 4000

```
JellyGoose is a player for the media server you already run. It finds your Jellyfin server on your network, you pick who's watching, and your films and shows are there: big, poster-forward and quick to move through.

A HOME THAT SHOWS YOU WHAT'S THERE
What you're part-way through leads the screen with its artwork and logo, ready to resume, with Continue Watching, Next Up and the newest in each library beneath it.

TAKE IT WITH YOU
Download films, episodes, whole seasons, albums, playlists and audiobooks, and play them with no server in reach: as they are, or a smaller copy your server makes, so a season fits. Where you got to is passed back to your server. Or have a show's next episodes download by themselves.

MUSIC AND AUDIOBOOKS
Your server's albums, artists and playlists, with lyrics, Up Next and Instant Mix, playing on in the background and in CarPlay. Audiobooks go chapter by chapter, at your speed, picking up where you stopped.

LIVE TV FROM YOUR OWN TUNER
Give your server a tuner, an HDHomeRun for one, and JellyGoose adds Live TV: a guide with your channel playing alongside, what's on now on Home, and recording of one showing or a whole series. Pause a channel or go back through it, turn on its captions, start a programme that's still recording from its beginning, and skip the marked commercials in a recording.

ASK FOR WHAT ISN'T THERE
Run Seerr beside your server and JellyGoose adds a Requests section: what's trending and popular. Ask for a film, a show or one season from wherever you are.

IT PLAYS WHAT THE SYSTEM PLAYER WON'T
H.264 and HEVC go to Apple's own player, where HDR and Dolby Vision belong. AV1, VP9, MPEG-2 and the rest go to a built-in VLC engine, played straight from the original file, so your server never has to re-encode anything.

BUILT FOR BIG FILES
4K remuxes start quickly and stay smooth: a film is made ready while you read its page.

PICTURE IN PICTURE, AND YOUR TV
Shrink a film to a corner of the screen and go on browsing. Or play it on an Apple TV running JellyGoose, with your phone as the remote.

WATCH TOGETHER
Start a group or join one, and a film plays for everyone at the same moment, each on their own screen.

LIBRARIES THAT KEEP UP
Move through thousands of titles, or jump to any letter. Choose several genres or decades at once, show only what you haven't watched, and each library remembers how you left it. Pin any view to the menu or to Home.

SUBTITLES THAT KEEP TIME
Pick a subtitle and it's there, on time, in any film. Choose its size, colour, background and height, or nudge its timing. When a film has none, search the internet from the player and it appears without the film restarting.

EVERYONE GETS THEIR OWN
Everyone who signs in gets a face on the sign-in screen: pick yours and you're in, with your own Continue Watching, watched marks, favourites and library settings, and iCloud carries your settings to your other devices.

THE LITTLE THINGS
Skip intros, recaps and credits, or have them skipped for you. Each show remembers its audio and subtitles. See the next episode coming as the credits roll. Preview frames while you scrub. Set a sleep timer. Watch a film's trailer. Get a notification when a new episode arrives. Ask Siri to carry on, add widgets to your Home Screen, and find a film from Spotlight.

FOR WHOEVER RUNS THE SERVER
See who's watching and how, send a message or stop playback, run the server's tasks, and manage its plugins.

MAKE IT YOURS
Six colour schemes, one a true black for OLED, six app icons, and Home's rows in the order you choose. In nine languages.

NOTHING PHONES HOME
No accounts, no subscription, no analytics, no advertising, no third parties. JellyGoose talks to your own servers and nowhere else, apart from asking your own network where they are during setup.

Requires your own Jellyfin server. Free to try for 7 days, then one purchase unlocks it on iPhone, iPad, Mac and Apple TV. Not affiliated with or endorsed by the Jellyfin project.
```

### Review notes — 3782 / 4000

```
JellyGoose is a client for Jellyfin and Emby media servers. It has no accounts and no content of its own: it plays what is on a server the user runs, so a server is required to see anything. The Apple TV and Mac versions are on the same App Store record.

For review, please use the Jellyfin project's public demo server:

1. Launch the app. On "Connect to your Jellyfin or Emby server", tap the address field and enter:
   demo.jellyfin.org
   (demo.jellyfin.org/stable and https://demo.jellyfin.org/stable work too.)
2. Tap Connect. The sign-in screen for "Stable Demo" appears. Enter user name "demo" and leave the password empty.
3. Tap Sign In. The home screen will show films, shows and music that can be browsed and played.

Free trial (Guideline 3.1.1): the app is free to download, and playing needs the free non-consumable "7-day Trial" or the non-consumable "JellyGoose Unlock". The first time anything is played, the unlock screen states the trial's length, that playing stops after it, and the unlock's price; tap Start Free Trial to go on. Browsing stays free. Restore Purchases is on that screen and in Settings > JellyGoose Unlock.

If the app says it couldn't reach a server, the address was not entered as above; the same server can be opened in a browser at https://demo.jellyfin.org/stable to confirm it is up.

New in 2.0, and what the demo server shows of it:

- Downloads take albums, playlists and audiobooks too (a download button on their pages), played from the device without the server.
- Download Quality (on the Downloads tab) has the server make a smaller copy of a film or episode as it downloads; the demo server's films download either way.
- New episode alerts (Settings > Playback) post a local notification when the user's server has added an episode of a show they watch. Off until turned on, which asks for permission; it looks through Background App Refresh.
- Dashboard (Settings > Dashboard) is for a Jellyfin server's administrators: sessions and how they play, Send Message, Stop Playback, scheduled tasks and the activity log. The demo account is not one, so it is absent there, as are Plugins and library management.
- JellyGoose for Mac is new on this record; the trial and the unlock are shared with it.

From 1.8: Music (in CarPlay too), Siri and Shortcuts, widgets and a downloads Live Activity, Spotlight, Keep Downloaded, Audiobooks, iCloud Sync (key-value storage, can be turned off) and Plugins (the server installs and runs them; the app runs no code, Guideline 2.5.2).

Downloads: a film's page has a download button, and the Downloads tab lists what is on the device. Picture in Picture: a button at the top of the player.

Watch Together works on the demo server: Watch Together > Start a Group in the menu, then play any film. Play on TV, under Play on a film's page, lists Apple TVs running JellyGoose on the same account; with none, the list says so.

CarPlay: the app holds the CarPlay Audio entitlement only. In every car it shows CarPlay's templates: Home, the libraries, Music, Search, and Live TV where the user's server has channels. In a car that supports video, a film plays with its picture while parked; otherwise, and while driving, as sound.

Earlier features that depend on the user's own server are absent on the demo server, as intended: Live TV (needs a tuner such as an HDHomeRun on the server, which tunes and records; the app has no channels of its own), Requests (a front end to the user's own Seerr), Search for Subtitles (through the server's own provider), and skipping marked intros, recaps and credits.

The app collects no data and contains no advertising or analytics. It communicates only with the servers the user chooses, and with the user's own iCloud for settings while iCloud Sync is on.
```

## Mac

### Promotional text — 140 / 170

```
New: JellyGoose on the Mac. Your library in a window of its own, music and audiobooks to go, smaller downloads, and alerts for new episodes.
```

### Description — 3980 / 4000

```
JellyGoose is a player for the media server you already run. It finds your Jellyfin server on your network, you pick who's watching, and your films and shows are there: big, poster-forward and quick to move through.

A HOME THAT SHOWS YOU WHAT'S THERE
What you're part-way through leads the screen with its artwork and logo, ready to resume, with Continue Watching, Next Up and the newest in each library beneath it.

A WINDOW OF ITS OWN
A film plays in a window of its own, so the rest of your library stays open beside it, and a double click fills the screen. The keyboard does what a remote does: space to pause, the arrows to skip and scrub, Escape to step back. Right-click any poster for its menu.

TAKE IT WITH YOU
Download films, episodes, whole seasons, albums, playlists and audiobooks to your Mac, and play them with no server in reach: as they are, or a smaller copy your server makes. Or have a show's next episodes download by themselves.

MUSIC AND AUDIOBOOKS
Your server's albums, artists and playlists, with lyrics, Up Next and Instant Mix, playing on while you work. Audiobooks go chapter by chapter, at your speed, picking up where you stopped.

LIVE TV FROM YOUR OWN TUNER
Give your server a tuner, an HDHomeRun for one, and JellyGoose adds Live TV: a guide with your channel playing alongside, what's on now on Home, and recording of one showing or a whole series. Pause a channel or go back through it, turn on its captions, start a programme that's still recording from its beginning, and skip the marked commercials in a recording.

ASK FOR WHAT ISN'T THERE
Run Seerr beside your server and JellyGoose adds a Requests section: what's trending and popular. Ask for a film, a show or one season from wherever you are.

IT PLAYS WHAT THE SYSTEM PLAYER WON'T
H.264 and HEVC go to Apple's own player, where HDR and Dolby Vision belong. AV1, VP9, MPEG-2 and the rest go to a built-in VLC engine, played straight from the original file, so your server never has to re-encode anything.

BUILT FOR BIG FILES
4K remuxes start quickly and stay smooth: a film is made ready while you read its page.

YOUR TV, AND EVERYONE'S
Play a film on an Apple TV running JellyGoose, with your Mac as the remote. Or start a Watch Together group, and a film plays for everyone at the same moment, each on their own screen.

LIBRARIES THAT KEEP UP
Move through thousands of titles, or jump to any letter. Choose several genres or decades at once, show only what you haven't watched, and each library remembers how you left it. Pin any view to the menu or to Home.

SUBTITLES THAT KEEP TIME
Pick a subtitle and it's there, on time, in any film. Choose its size, colour, background and height, or nudge its timing. When a film has none, search the internet from the player and it appears without the film restarting.

EVERYONE GETS THEIR OWN
Everyone who signs in gets a face on the sign-in screen: pick yours and you're in, with your own Continue Watching, watched marks, favourites and library settings, and iCloud carries your settings to your other devices.

THE LITTLE THINGS
Skip intros, recaps and credits, or have them skipped for you. Each show remembers its audio and subtitles. See the next episode coming as the credits roll. Set a sleep timer. Keep a watchlist of films. Get a notification when a new episode arrives.

FOR WHOEVER RUNS THE SERVER
See who's watching and how, send a message or stop playback, run the server's tasks, and manage its plugins.

MAKE IT YOURS
Six colour schemes, one a true black, and Home's rows in the order you choose. In nine languages.

NOTHING PHONES HOME
No accounts, no subscription, no analytics, no advertising, no third parties. JellyGoose talks to your own servers and nowhere else, apart from asking your own network where they are during setup.

Requires your own Jellyfin server. Free to try for 7 days, then one purchase unlocks it on your Mac, iPhone, iPad and Apple TV. Not affiliated with or endorsed by the Jellyfin project.
```

### Review notes — 3968 / 4000

```
JellyGoose is a client for Jellyfin and Emby media servers. It has no accounts and no content of its own: it plays what is on a server the user runs, so a server is required to see anything. The Apple TV, iPhone and iPad versions are on the same App Store record (Universal Purchase); this is the first Mac version, numbered 2.0 with the others.

For review, please use the Jellyfin project's public demo server:

1. Open the app. On "Connect to your Jellyfin or Emby server", click the address field and enter:
   demo.jellyfin.org
   (demo.jellyfin.org/stable and https://demo.jellyfin.org/stable work too.)
2. Click Connect. The sign-in screen for "Stable Demo" appears. Enter user name "demo" and leave the password empty.
3. Click Sign In. The home screen will show films, shows and music that can be browsed and played.

Free trial (Guideline 3.1.1): the app is free to download, and playing needs the free non-consumable "7-day Trial" or the non-consumable "JellyGoose Unlock", the same two purchases as on the other platforms. The first time anything is played, the unlock screen states the trial's length, that playing stops after it, and the unlock's price; click Start Free Trial to go on. Browsing stays free. Restore Purchases is on that screen and in Settings > JellyGoose Unlock.

If the app says it couldn't reach a server, the address was not entered as above; the same server can be opened in a browser at https://demo.jellyfin.org/stable to confirm it is up.

How the Mac version works:

- One window. A film plays in a window of its own, which its close button, Escape or the player's own controls close, saving where it got to. A double click or F fills the screen. Space pauses; the arrow keys skip and scrub.
- A right click on any poster opens its menu (Play from Beginning, Mark as Watched, Download and more).
- The menu bar has Go, Controls, and Settings… on Command-comma.
- Downloads: a film's page has a download button, as do album, playlist and audiobook pages; Downloads in the side menu lists what is on the Mac, kept in the app's own container, and sets the quality (Original, or a smaller copy the server makes).
- New episode alerts (Settings > Playback) post a local notification, hourly while the app runs, when the user's server has added an episode of a show they watch. Off until turned on, which asks for permission.
- Dashboard (Settings > Dashboard) is for a Jellyfin server's administrators: who is watching what and how, Send Message, Stop Playback, scheduled tasks and the activity log. The demo account is not one, so it is absent there.
- Music: the demo server's Music library is in the menu, with a mini player at the foot of the window.

Watch Together works on the demo server (Watch Together > Start a Group, then play a film). Play on TV lists Apple TVs running JellyGoose on the same account.

iCloud Sync (Settings > iCloud Sync) shares the app's own settings between the user's devices through iCloud key-value storage, and can be turned off. Plugins (Settings > Plugins) lets the administrator of a Jellyfin server install, update, switch off and remove that server's plugins, from the catalogue the server itself offers; the server downloads and runs them, and the app downloads and runs no code (Guideline 2.5.2). Only administrators see it; the demo account is not one, so it is absent there, as is library management.

Features that depend on the user's own server are absent on the demo server, as intended: Live TV (needs a tuner such as an HDHomeRun on the server, which tunes and records; the app has no channels of its own), Requests (a front end to the user's own Seerr), Search for Subtitles (through the server's own provider), Audiobooks and Coming Soon, and skipping marked intros, recaps and credits.

The app collects no data and contains no advertising or analytics. It communicates only with the servers the user chooses, and with the user's own iCloud for settings while iCloud Sync is on.
```
