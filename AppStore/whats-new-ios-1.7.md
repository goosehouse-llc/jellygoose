# JellyGoose 1.7 — App Store copy (iPhone and iPad)

For the iPhone and iPad's 1.7 (build 99), to go out the same day as the Apple
TV's 1.7, when the app starts to cost $3.99 (then $4.99; Sam, 2026-10-17).
It takes the place of iOS 1.4 (build 50), which has waited for review since
2026-10-11: that entry is withdrawn from review, renamed 1.7, given this text
and build 99, set to release manually, and submitted. No iPhone version has
been released yet, so this is the first: there is no What's New field.
Keywords and the nine screenshots per device stay as 1.4's (`listing-ios.md`).

## Promotional text — 142 / 170

```
Your Jellyfin server on iPhone and iPad: films, shows and Live TV, downloads to watch offline, and your phone as the remote for your Apple TV.
```

## Description — 3958 / 4000

1.5's (`whats-new-ios-1.5.md`) with Watch Together, Play on TV, Live TV's
newer parts, recaps, the sleep timer and trailers added; paid for with "Run
the server from the sofa", the A to Z, the nineties comedies, Seerr's genre
and studio browsing, and two longer sentences. No tip jar, and no word of
CarPlay until it's been seen in a car (it is in the review notes, since it's
in the build).

```
JellyGoose is a player for the media server you already run. It finds your Jellyfin server on your network, you pick who's watching, and your films and shows are there: big, poster-forward and quick to move through.

A HOME THAT SHOWS YOU WHAT'S THERE
What you're part-way through leads the screen with its artwork and logo, ready to resume, with Continue Watching, Next Up and the newest in each library beneath it.

TAKE IT WITH YOU
Download a film, an episode or a whole season to your iPhone or iPad and watch it with no server in reach. Downloads wait for Wi-Fi unless you say otherwise, and where you got to is passed back to your server when you're home.

LIVE TV FROM YOUR OWN TUNER
Give your server a tuner, an HDHomeRun for one, and JellyGoose adds Live TV: a guide to what's on and what's next with your channel playing alongside, what's on now on Home, and recording of one showing or a whole series. Pause a channel or go back through it, turn on its captions, start a programme that's still recording from its beginning, skip the marked commercials in a recording, and find what's on from Search.

ASK FOR WHAT ISN'T THERE
Run Seerr beside your server and JellyGoose finds it and adds a Requests section: what's trending, popular and coming soon. Ask for a film, a show or one season from wherever you are.

IT PLAYS WHAT THE SYSTEM PLAYER WON'T
H.264 and HEVC go to Apple's own player, where HDR and Dolby Vision belong. AV1, VP9, MPEG-2 and the rest go to a built-in VLC engine, played straight from the original file, so your server never has to re-encode anything.

BUILT FOR BIG FILES
4K remuxes start quickly and stay smooth: a film is made ready while you read its page, and JellyGoose asks for the untouched stream rather than a live re-encode. A Stats button shows which player has the film, and whether your server is converting anything and why. Every title shows its resolution, HDR format and codecs.

PICTURE IN PICTURE, AND YOUR TV
Shrink a film to a corner of the screen and go on browsing, in the app or out of it. Or play it on an Apple TV running JellyGoose, with your phone as the remote.

WATCH TOGETHER
Start a group or join one, and a film plays for everyone at the same moment, each on their own screen. A pause or a skip is everyone's.

LIBRARIES THAT KEEP UP
Move through thousands of titles, or jump to any letter. Sort seven ways, either way round. Choose several genres or decades at once, show only what you haven't watched, and each library remembers how you left it. Pin any view to the menu.

SUBTITLES THAT KEEP TIME
Pick a subtitle and it's there, on time, in any film. Choose its size, colour, background and height, or nudge its timing earlier or later. When a film has none, search the internet from the player and it appears without the film restarting.

EVERYONE GETS THEIR OWN
Everyone who signs in gets a face on the sign-in screen: pick yours and you're in, with your own Continue Watching, watched marks, favourites and library settings. Your place is kept on the server, in step with every other app you use.

THE LITTLE THINGS
Skip intros, recaps and credits, or have them skipped for you. See the next episode coming as the credits roll. Preview frames while you scrub. Set a sleep timer. Watch a film's trailer. Keep a watchlist of films.

FOLLOW A FACE, OR A STUDIO
Choose anyone in the cast for a short biography and everything else they're in that you own, or a studio for everything of theirs.

MAKE IT YOURS
Six colour schemes, one a true black for OLED, six app icons, and Home's rows in the order you choose. In nine languages.

NOTHING PHONES HOME
No accounts, no subscription, no analytics, no advertising, no third parties. JellyGoose talks to your own servers and nowhere else, apart from asking your own network where they are during setup.

Requires your own Jellyfin server. Free to try for 7 days, then one purchase unlocks it here and on Apple TV. Not affiliated with or endorsed by the Jellyfin project.
```

## Review notes — 3924 / 4000

1.4's (`listing-ios.md`), with the tip jar gone and Watch Together, Play on
TV and CarPlay said. CarPlay's paragraph rewritten for build 102 (2026-10-21):
build 101 was rejected under Guideline 2.5.1 for holding both the CarPlay
Video and Audio entitlements, so the app keeps Audio alone, and with it no
window of its own on a car's screen.

```
JellyGoose is a client for Jellyfin and Emby media servers. It has no accounts and no content of its own: it plays what is on a server the user runs, so a server is required to see anything. The Apple TV version is on the same App Store record.

For review, please use the Jellyfin project's public demo server:

1. Launch the app. On "Connect to your Jellyfin or Emby server", tap the address field and enter:
   demo.jellyfin.org
   (demo.jellyfin.org/stable and https://demo.jellyfin.org/stable work too.)
2. Tap Connect. The sign-in screen for "Stable Demo" appears. Enter user name "demo" and leave the password empty.
3. Tap Sign In. The home screen will show films and shows that can be browsed and played.

Free trial (Guideline 3.1.1): the app is free to download, and playing needs the free non-consumable "7-day Trial" or the non-consumable "JellyGoose Unlock". The first time anything is played, the unlock screen states the trial's length, that playing stops after it, and the unlock's price; tap Start Free Trial to go on. Browsing stays free. Restore Purchases is on that screen and in Settings > JellyGoose Unlock.

If the app says it couldn't reach a server, the address was not entered as above; the same server can be opened in a browser at https://demo.jellyfin.org/stable to confirm it is up.

The demo account is not an administrator, so Settings' library management is inactive there.

Downloads: a film's page has a download button, and the Downloads tab lists what is on the device. Picture in Picture: a button at the top of the player shrinks the film to a corner while the rest of the app is used.

Watch Together works on the demo server: Watch Together > Start a Group in the menu, then play any film; a second device, or Jellyfin's web player, can join. It is Jellyfin's SyncPlay. Play on TV, under Play on a film's page, lists Apple TVs running JellyGoose on the same account and plays the film there, with this device as the remote; with no Apple TV on the account the list says so. Both use the user's own server and nothing else.

CarPlay: the app holds the CarPlay Audio entitlement only (the CarPlay Video entitlement was removed, as App Review asked of build 101). In every car it shows CarPlay's templates: Home with Continue Watching and Next Up, the libraries, Search, and Live TV where the user's server has channels. In a car that supports video, a film or channel plays with its picture while the car is parked; otherwise, and while driving, it plays as sound.

Parts of the app that depend on the user's own server, and how much of each the demo server shows:

- Live TV. A Jellyfin server can be given a television tuner, and then lists its channels and a programme guide. Where the user's own server has one, JellyGoose adds a Live TV section: the guide, the channel being watched, and a row on Home of what is on now. The app receives nothing over the air itself and has no channels of its own. The demo server has no tuner, so on it there is no Live TV in the menu, no "On Now" row on Home and no Live TV entry in Settings.
- Requests. Where the user's own server has Seerr (an open-source request manager) beside it, JellyGoose adds a Requests section that is a front end to it; the app itself fetches nothing. The demo server has none, so the section isn't in the menu.
- Search for Subtitles, at the foot of the player's Subtitles menu, asks the user's server to search the subtitle provider its owner has set up. It is shown only to accounts allowed to manage subtitles, which the demo account is not.
- Settings > Playback has "Skip intros automatically" and "Skip credits automatically". They act where a server marks intros and credits, which the demo server's films do not.

The app collects no data, contains no advertising or analytics, and communicates only with the servers the user chooses.
```

## Screenshots and header (entered 2026-10-17)

Ten a device (a set's limit), in this order: 01 Matrix, 02 Home, **09 Live
TV's guide**, **10 a channel full screen with its controls up**, then 03 to
08 as on 1.4. The two Live TV shots are new: taken on the throwaway server's
made-up channels and listings, with generated pictures (`fakehdhr.py` with
`FANCY=1`, `guide.py` with `WILD=1` so no row says it has no guide), so no
one's programmes are on the store page; the old guide shot showed a real
station. `test9LiveTV` and `test10LiveFull` in
`AppStore/UITests-iOS/StoreShotsiOSUITests.swift`; the iPad's on a fresh
simulator (the shared iPad Pro 13 showed another app's "◀ Redde" in its
status bar); turned upright with `Tools/upright.swift`.

Header: `AppStore/header/header-ios-3840x1646.png` from `header-ios.html`,
the Apple TV's header with a car's CarPlay screen, an iPad on Live TV's guide
and an iPhone in place of the television screens; no text. Uploaded to the
asset library (image 92c00019…, awaiting Apple's review) and placed on this
entry in place of the Apple TV's header, which was there for a moment first.
