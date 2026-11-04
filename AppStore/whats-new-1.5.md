# JellyGoose 1.5 — App Store copy (Apple TV)

For the Apple TV's 1.5 version (build 57 or later). 1.4 went live on
2026-10-12 with Live TV in it; 1.5 is everything built on Live TV in the two
days after. The description gains a sentence on pausing a channel and its
captions, in `listing.md`; the review notes say that all of 1.5 is inside
Live TV, which the demo server hasn't got, in `review-notes.md`. Keywords and
screenshots are 1.4's.

## What's New — 1240 / 4000

```
• Pause and rewind Live TV: left and right go back and forward through the channel you're watching, and Play/Pause holds it. As far back as when you tuned in, up to half an hour, kept on the Apple TV while you watch. There's a switch for it in Settings, under Live TV
• Captions: press Up while a channel fills the screen to turn on its closed captions. Your choice is kept for the next channel
• Audio Sync for Live TV, in the same panel: move the sound earlier or later where it's out of step with your loudspeaker. It's kept for each kind of loudspeaker
• What's on: press Down for a card with the programme, its episode, what it's rated, what it's about and what follows. With the card up, left and right change channel
• Record Series for any programme, not only numbered episodes: the evening news, every night. A long press on a card in On Now offers recording too, and a card that's recording says so
• The guide names the episode in each square, and leads with it on a channel that shows one series all day
• The guide marks only the showings that will be recorded. It used to mark every showing of a series, the ones the server passes over included
• Fixed: with the sound going to a HomePod, voices on Live TV came after the lips
```

The last line went in on 2026-10-12, once it had been heard: the change (the
player keeps as much in hand as the loudspeaker's delay and a second over)
had only been tried by pretending the delay in the simulator, and the text
waited until the voices were in step on a real HomePod.

The app's own What's New card (`WhatsNew.items`, "1.5") has five of these in
all nine languages on the Apple TV (pause and rewind, captions with Audio
Sync, the card of what's on, a series for any show, episodes in the guide)
and four on an iPhone or iPad, which have no card of what's on.

## Promotional text — 135 / 170

```
New in 1.5: pause and rewind Live TV, turn on a channel's captions, and set a series recording for any show, the evening news included.
```

## What the store text leans on

Each of these is a claim someone can check, so before the copy is reused:

- **Pause and rewind** reaches back to when the channel was tuned, at most
  half an hour and about four gigabytes, less on a device short of room. It's
  kept in the app's temporary files and deleted when the channel is left or
  changed. Not for a stream the server is converting (a quality limit set
  under what the station sends): there, left and right change channel as
  they did. Going to another place in it starts the player again from
  there, a second or so of black. Checked packet for packet outside the app
  and watched in the simulators against a real tuner; **not watched on a
  real Apple TV when this was written.**
- **Captions** are the ones a broadcast carries inside its picture (CEA-608),
  found a few seconds after a channel starts. A channel that sends none has
  an empty list, and says so. The names are the player's ("Closed captions
  1"), in English in every language.
- **Audio Sync** is a tenth of a second at a press, two seconds either way,
  kept by the kind of output (AirPlay, HDMI, Bluetooth), on the Apple TV
  only.
- **The card of what's on** shows the programme's own picture where the
  listings have one and the station's mark where they haven't; what it's
  rated only where the listings say.
- **A series for any programme** is the server's doing once it's set. For a
  programme the listings don't number, Jellyfin records one showing each
  time it reads the listings (the next it can see): every night for a
  programme that's on once a night under its own name, and not every
  showing of one that's on all day under one name. Films aren't offered it.
- **Left and right changing channel with the card up** replaces what 1.4's
  text said ("change channel from there"), which was up and down.
