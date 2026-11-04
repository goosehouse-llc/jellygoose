# JellyGoose 1.3 — App Store copy (Apple TV)

For the Apple TV's 1.3 version (build 31 or later). The description is new,
in `listing.md`; the review notes have a paragraph on what 1.3 adds, in
`review-notes.md`. Keywords are 1.2.2's, carried over. The screenshots were
retaken on build 31 and two of Requests added, ten in all: see `listing.md`.

## What's New — 1405 / 4000

```
• Requests: with Seerr beside your Jellyfin server, see what's trending, popular and coming soon, by genre, studio and network, and ask for films and shows from the sofa. The section appears in the menu by itself when your server has one
• Intros and credits can be skipped for you: two switches in Settings, under Playback. Credits go straight on to the next episode
• Search the internet for subtitles from the player's Subtitles menu, through your server's own subtitle provider. The one you pick appears without the film restarting
• Subtitles in a colour, on a background and at a height of your choosing, with a preview as you choose (Settings, Subtitles)
• A watchlist for films: add one from its page or with a long press, and watching it takes it off
• Search finds people and collections as well as films and shows
• Home videos, music videos and mixed libraries now appear with the rest
• A Stats button in the player shows which player has the film, whether your server is converting it and why, and how the stream is holding up
• Audio Sync in the player: move a film's sound earlier or later when it's out of step, or have it worked out from the subtitles
• Fixed: a film with a subtitle file beside it was being converted by the server instead of playing straight from the file
• Fixed: on MKV files with a subtitle file beside them, audio and subtitle tracks could carry each other's names
```

The app's own What's New card (`WhatsNew.items`, "1.3") has six of these, in
all nine languages: Requests, skipping, subtitles, the watchlist, Search and
Stats.

## Promotional text — 152 / 170

```
New in 1.3: ask for films through Seerr, find subtitles from the player, have intros and credits skipped for you, and see exactly how a film is playing.
```

## What the store text leans on

Each of these is a claim someone can check, so before the copy is reused:

- **Requests** appears by itself only where a Seerr answers on the server's
  own machine at port 5055; anywhere else its address is typed in Settings,
  under Requests. Sign-in is by Quick Connect, so Jellyfin only: on Emby the
  section isn't offered.
- **Finding subtitles** is the server's doing. The entry is in the player's
  Subtitles menu only for an account allowed to manage subtitles, and it
  finds something only where the server has a subtitle provider with an
  account behind it (Open Subtitles, usually).
- **Skipping for you** acts on intros and credits the server marks: the Intro
  Skipper plugin's, or chapters named for them. Credits the app only guessed
  at from an unnamed last chapter are offered as a button and never skipped
  unasked.
- **The watchlist** is films only, and is kept on the server as the film's
  "Likes" mark, so it follows the account to other devices running JellyGoose
  and to nothing else.
