# JellyGoose for iPhone and iPad — App Store copy

The iOS version on the same App Store record as the Apple TV app (one bundle
ID, Universal Purchase). First set up as 1.2.1 (build 13, then 14) on
2026-10-02, which waited nine days for review without being looked at and
was taken out of review on 2026-10-11. Its entry was then made 1.4: the
version number changed, and everything below entered in its place, with
build 50. So 1.4 is the first version these devices have. 1.2.1's and 1.3's
copy are in this file's history. The name, subtitle, links, privacy answers
and age rating are the
record's own and shared with the Apple TV version; see `listing.md`.

## What's New and promotional text

In [`whats-new-ios-1.4.md`](whats-new-ios-1.4.md). A version that is the
first on these devices has no What's New.

## Description — 3937 / 4000

The Apple TV's 1.4 description with what differs here: the Home is the banner
one, Downloads is this app's alone, picture in picture and AirPlay have a
paragraph, and the Apple TV's Top Shelf, frame-rate matching, lossless 7.1 and
remote aren't mentioned, nor moving a film's sound, which is offered for few
films here. The paragraph on Live TV and Home's rows were paid for with: the
streaming-service aside in the opening, the random handful, watching a scan's
progress, when the film will end, the audio layout and bitrate among what a
title shows, the heading over "picks up where you left off" (its sentence is
under "Everyone gets their own"), and the nine languages by name.

```
JellyGoose is a player for the media server you already run. It finds your Jellyfin server on your network, you pick who's watching, and your films and shows are there: big, poster-forward and quick to move through.

A HOME THAT SHOWS YOU WHAT'S THERE
What you're part-way through leads the screen with its artwork and logo, ready to resume, with Continue Watching, Next Up and the newest in each library beneath it.

TAKE IT WITH YOU
Download a film, an episode or a whole season to your iPhone or iPad and watch it with no server in reach. Downloads wait for Wi-Fi unless you say otherwise, and where you got to is passed back to your server when you're home.

LIVE TV FROM YOUR OWN TUNER
Give your server a tuner, an HDHomeRun for one, and JellyGoose adds Live TV: a guide to what's on and what's next with your channel playing alongside, what's on now on Home, and recording of one showing or a whole series.

ASK FOR WHAT ISN'T THERE
Run Seerr beside your server and JellyGoose finds it and adds a Requests section: what's trending, popular and coming soon, by genre, studio and network. Ask for a film, a show or one season from wherever you are.

IT PLAYS WHAT THE SYSTEM PLAYER WON'T
H.264 and HEVC go to Apple's own player, where HDR and Dolby Vision belong. AV1, VP9, MPEG-2 and the rest go to a built-in VLC engine, played straight from the original file, so your server never has to re-encode anything.

BUILT FOR BIG FILES
4K remuxes start quickly and stay smooth: a film is made ready while you read its page, and JellyGoose asks for the untouched stream rather than a live re-encode. A Stats button shows which player has the film, and whether your server is converting anything and why. Every title shows its resolution, HDR format and codecs.

PICTURE IN PICTURE AND AIRPLAY
Shrink a film to a corner of the screen and go on browsing, in the app or out of it, or send it to an Apple TV.

LIBRARIES THAT KEEP UP
Move through thousands of titles, or jump to any letter from the A to Z down the side. Sort seven ways, either way round. Choose several genres or decades at once, show only what you haven't watched, and each library remembers how you left it. Pin any view to the menu, like unwatched comedies from the nineties.

SUBTITLES THAT KEEP TIME
Pick a subtitle and it's there, on time, in any film. Choose its size, colour, background and height, or nudge its timing earlier or later. When a film has none, search the internet from the player: your server fetches the one you pick, and it appears without the film restarting.

EVERYONE GETS THEIR OWN
Everyone who signs in gets a face on the sign-in screen: pick yours and you're in, with your own Continue Watching, watched marks, favourites and library settings. Your position is reported to the server as you watch, so Continue Watching stays in step with every other app you use.

THE LITTLE THINGS
Skip intros and credits, or have them skipped for you. Jump between chapters. See the next episode coming as the credits roll. Preview frames while you scrub. Change the playback speed. Keep a watchlist of films. Mark a season watched in one go. Shuffle a show, or play a collection straight through.

FOLLOW A FACE, OR A STUDIO
Choose anyone in the cast for a short biography and everything else they're in that you own. Choose a studio or network to see everything else of theirs.

RUN THE SERVER FROM THE SOFA
Add, rename and remove libraries and folders, scan for changes or refresh metadata.

MAKE IT YOURS
Six colour schemes, one a true black for OLED, six app icons, and Home's rows in the order you choose. In nine languages.

NOTHING PHONES HOME
No accounts, no subscription, no analytics, no advertising, no third parties. JellyGoose talks to your own servers and nowhere else, apart from asking your own network where they are during setup.

Requires your own Jellyfin server. Also on Apple TV. Not affiliated with or endorsed by the Jellyfin project.
```

## Keywords — 99 / 100

The set the Apple TV's 1.4 has, Seerr and Live TV both (see `listing.md`):

```
jellyfin,media server,self hosted,home theater,movies,tv shows,nas,seerr,seer,live tv,dvr,hdhomerun
```

1.2.1's entry has the older set (`…,nas,library,video player`). Keywords are
each platform's own field on each version, and can't be changed while a
version is in review.

## Screenshots

`AppStore/final-ios/`, nine for the iPhone 6.9-inch display (1320×2868; the
player on its side, 2868×1320) and nine for the iPad 13-inch (2752×2064, on
its side), retaken on 1.4 on 2026-10-11. In upload order, with Live TV third
as on the Apple TV:

1. The Matrix Resurrections' page (`01-matrix`)
2. Home, on Bluey part-watched (`02-home`)
3. Live TV: the guide, with the channel that's on playing above it on an
   iPhone and in the corner on an iPad (`09-livetv`)
4. Bluey's page (`03-show`)
5. The Movies library at B, with the A to Z down the side (`04-library`)
6. 13 Hours playing, the controls up (`05-player`)
7. Downloads (`06-downloads`)
8. Requests, under Seerr's mark (`07-requests`)
9. Asking for a show: the panel over The Good Place (`08-asking`)

They come from a UI test (`AppStore/UITests-iOS/StoreShotsiOSUITests.swift`)
on the iPhone 17 Pro Max and iPad Pro 13-inch simulators, signed in to the
real server as the JellyGoose profile, with the profile's Continue Watching
arranged as for the Apple TV's set (see `listing.md`) and put back after.
The status bar is set first (`xcrun simctl status_bar <id> override --time
9:41 --batteryState charged --batteryLevel 100 --wifiBars 3`). A capture of
a device on its side is the upright picture with a note to turn it: the
pixels have to be turned before it's uploaded, which `Tools/upright.swift`
does (every iPad shot, and the iPhone's player). Downloads wants two
episodes on the device (`testSetUpDownloads` fetches them, and answers the
question the first download asks), and a simulator with nothing on it is
signed in by giving the test the server, name and password (`JG_SERVER`,
`JG_USER`, `JG_PASS`). Home is taken while Bluey leads Continue Watching,
so before the player, which brings 13 Hours to the front. The player is
taken five times, a few seconds apart: a line of dialogue on screen is
drawn up among the buttons while the controls are up, and one without is
the one to keep. The asking panel is opened and cancelled, as on the Apple
TV: nothing is asked for.

The Live TV shot has the home server's own tuner behind it, so its picture
is whatever was on the air: six are taken four seconds apart, to choose one
with no face and no sponsor's card in it. `LIVE_CHANNEL` (a channel's id)
says which channel the page opens on; a public station's cookery channel
was the one used. The guide shows the time of day, so for this shot alone
the status bar is set to the real time, at the top of a minute, and the
test started at once: the six are all taken inside that minute. The test
leaves by way of Home, which lets the tuner go, and fails if the guide is
still there afterwards. A test killed on the guide leaves the server
holding a tuner for nobody: check the tuner's own status page after, and
close the stream by the server's API if it's still held.

The iPad's player now shows the Picture in Picture button beside AirPlay.
The iPhone's doesn't: a simulated iPhone has no Picture in Picture, and
the button is only drawn where the device has it.

## Review notes — 3422 / 4000

```
JellyGoose is a client for Jellyfin and Emby media servers. It has no accounts and no content of its own: it plays what is on a server the user runs, so a server is required to see anything. The Apple TV version is on the same App Store record.

For review, please use the Jellyfin project's public demo server:

1. Launch the app. On "Connect to your Jellyfin or Emby server", tap the address field and enter:
   demo.jellyfin.org
   (demo.jellyfin.org/stable and https://demo.jellyfin.org/stable work too.)
2. Tap Connect. The sign-in screen for "Stable Demo" appears. Enter user name "demo" and leave the password empty.
3. Tap Sign In. The home screen will show films and shows that can be browsed and played.

If the app says it couldn't reach a server, the address was not entered as above; the same server can be opened in a browser at https://demo.jellyfin.org/stable to confirm it is up.

That server is public and read-only, and its libraries are public-domain films. The library management features in Settings are inactive there because the demo account is not an administrator.

Downloads: a film's page has a download button, and the Downloads tab lists what is on the device. Picture in Picture: a button at the top of the player shrinks the film to a corner while the rest of the app is used. The tip jar in Settings uses three consumable in-app purchases already approved for the Apple TV version.

Parts of the app that depend on the user's own server, and how much of each the demo server shows:

- Live TV. A Jellyfin server can be given a television tuner (an HDHomeRun on the home network, for instance), and then lists its channels and a programme guide. Where the user's own server has one, JellyGoose adds a Live TV section: the guide, the channel being watched, and a row on Home of what is on now. Accounts the server's owner allows can set a programme or a series to record; the server does the recording and keeps it. The app receives nothing over the air itself and has no channels of its own. The demo server has no tuner, so on it there is no Live TV in the menu, no "On Now" row on Home and no Live TV entry in Settings. That is the app as intended, not something missing.
- Requests. Some people run Seerr, an open-source request manager, beside their media server: members of the household ask for a title there, and the person who runs the server approves or declines it. Where the user's own server has one, JellyGoose adds a Requests section that is a front end to it. The app shows what that Seerr lists and passes the request to it; the app itself fetches nothing and has no source of content of its own. The demo server has no Seerr, so the section is not in the menu there, and Settings > Requests says none was found.
- Search for Subtitles, at the foot of the player's Subtitles menu, asks the user's server to search the subtitle provider its owner has set up. It is shown only to accounts allowed to manage subtitles, which the demo account is not.
- Settings > Playback has "Skip intros automatically" and "Skip credits automatically". They act where a server marks intros and credits, which the demo server's films do not.

Settings > Home Screen puts Home's rows in the order the user chooses and switches any of them off; it works on the demo server.

The app collects no data, contains no advertising or analytics, and communicates only with the servers the user chooses.
```

Written so as to read the same whether 1.4 is the first version a reviewer
sees on these devices or the second: nothing in it says "new in".

## What was entered, 2026-10-11

1.2.1 was withdrawn ("Remove this version from review" on the iOS entry),
which leaves the entry editable, and the same entry became 1.4:

1. Its version number changed from 1.2.1 to 1.4.
2. The description, keywords, promotional text and review notes replaced
   with the ones here. A first version has no What's New.
3. The six screenshots for each device replaced with the nine, in the
   order above.
4. Build 50, uploaded from Xcode's Organizer (the archive
   `JellyGoose-iOS-1.4-50`), chosen in place of build 14.

Steps 1 to 4 went through the API with the key that made the Apple TV's
entries; uploading can't (the key can't sign for distribution), and
submitting is done in App Store Connect.

## Not in this build

CarPlay: the scene and its player are in the code, but a device build leaves
the scene out of its Info.plist until Apple grants the CarPlay video
entitlement (see `project.yml`).
