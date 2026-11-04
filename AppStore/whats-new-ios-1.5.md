# JellyGoose 1.5 — App Store copy (iPhone and iPad)

For the iPhone and iPad's 1.5 version (build 57 or later). Written on
2026-10-12 with their 1.4, the first version these devices have, a day into
waiting for review: nothing here is in App Store Connect, and a 1.5 entry
can't be made for iOS until 1.4 is through (or is taken out of review and
made 1.5, as 1.2.1 was made 1.4). The Apple TV's 1.5 is in `whats-new-1.5.md`.

If 1.5 follows 1.4, this is its What's New; if it takes 1.4's place it is the
first version here and has none.

## What's New — 811 / 4000

```
• Pause and rewind Live TV: the buttons over the picture hold a channel and go back and forward through it. As far back as when you tuned in, up to half an hour, kept on the device while you watch. There's a switch for it in Settings, under Live TV
• Captions: the captions button over the picture turns on a channel's closed captions. Your choice is kept for the next channel
• Record Series for any programme, not only numbered episodes: the evening news, every night. A long press on a card in On Now offers recording too, and a card that's recording says so
• The guide names the episode in each square, and leads with it on a channel that shows one series all day
• The guide marks only the showings that will be recorded. It used to mark every showing of a series, the ones the server passes over included
```

Not in it: the card of what's on and Audio Sync, which are the Apple TV's.

## Promotional text — 135 / 170

```
New in 1.5: pause and rewind Live TV, turn on a channel's captions, and set a series recording for any show, the evening news included.
```

## Description — 3952 / 4000

1.4's (`listing-ios.md`) with one sentence added to the paragraph on Live TV,
paid for with jumping between chapters and changing the playback speed:

```
JellyGoose is a player for the media server you already run. It finds your Jellyfin server on your network, you pick who's watching, and your films and shows are there: big, poster-forward and quick to move through.

A HOME THAT SHOWS YOU WHAT'S THERE
What you're part-way through leads the screen with its artwork and logo, ready to resume, with Continue Watching, Next Up and the newest in each library beneath it.

TAKE IT WITH YOU
Download a film, an episode or a whole season to your iPhone or iPad and watch it with no server in reach. Downloads wait for Wi-Fi unless you say otherwise, and where you got to is passed back to your server when you're home.

LIVE TV FROM YOUR OWN TUNER
Give your server a tuner, an HDHomeRun for one, and JellyGoose adds Live TV: a guide to what's on and what's next with your channel playing alongside, what's on now on Home, and recording of one showing or a whole series. Pause a channel or go back through it, and turn on its captions.

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
Skip intros and credits, or have them skipped for you. See the next episode coming as the credits roll. Preview frames while you scrub. Keep a watchlist of films. Mark a season watched in one go. Shuffle a show, or play a collection straight through.

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

## Review notes

1.4's, with the paragraph on pausing and rewinding from the Apple TV's
(`review-notes.md`): while a channel is watched the app keeps up to half an
hour of it in its temporary files, deleted when the channel is left, and
Settings > Live TV switches that off.

## What it leans on

As for the Apple TV (`whats-new-1.5.md`). By touch the three buttons are back
ten seconds, hold, and forward ten. Tried in the iPhone simulator against a
test server; **not on a real phone when this was written.**
