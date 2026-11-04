# JellyGoose 1.7 — App Store copy (Apple TV)

For the Apple TV's 1.7 version. 1.6 went live on 2026-10-15; 1.7 is everything
built since (builds 87 to 96 and the fixes before the archive). The description
in `listing.md` gains Play on TV, trailers and theme music; the review notes in
`review-notes.md` say what the demo server shows of it. Keywords are 1.4's to
1.6's.

## What's New — 1061 / 4000

```
• Play on TV: send a film, an episode or a whole show to this Apple TV from Jellyfin's web app, on a phone or a computer, and pause it, move through it or change its sound and subtitles from there. Give the Apple TV a name in Settings, Playback, so it's easy to pick out
• SDR video in HDR: a switch in Settings, Playback keeps the TV in HDR for everything, for a brighter picture on TVs whose HDR runs brighter than their standard mode
• Skip recaps and previews: an episode's "previously on" and its look at the next one, where your server marks them, offered like an intro, or skipped for you by a switch in Settings
• Trailers: a Trailer button on a film's or show's page, playing the one on your server, or the one on YouTube where the YouTube app is installed
• Theme music: a show's or film's theme song plays quietly on its page where your server has one. A switch in Settings turns it off
• Recordings: each one on its own card, with the day it aired and the show's artwork or the programme's picture, and new ones there as soon as you open the library
```

The app's own What's New card (`WhatsNew.items`, "1.7") has five items in all
nine languages on the Apple TV (Play on TV, SDR video in HDR, skipping recaps
and previews, trailers and theme music, recordings). An iPhone or iPad gets
its own Play on TV (the phone as the remote) and CarPlay in place of the first
two, for when the iPhone's version carries 1.7.

Neither the store text nor the TV's card says a film can be sent from
JellyGoose on an iPhone: that half ships with the iPhone's next version, and
iOS 1.4 is still in review. When it's out, the promotional text (editable
without a build) is the place to say so.

## Promotional text — 127 / 170

```
New in 1.7: send a film to the Apple TV from Jellyfin on your phone or computer, plus trailers, theme music and skipped recaps.
```

## What the store text leans on

Each of these is a claim someone can check:

- **Play on TV** is Jellyfin's remote control: the Apple TV app tells the
  server it can be sent films (while it's open and the switch in Settings is
  on), and the server passes on what the web app or a phone asks. Jellyfin's
  web app lists every session the account may control (its cast button, "Play
  on"), and sends a show or season as it is; the TV plays a show's next
  episode, a season or collection through, and Shuffle mixed. Tested
  2026-10-16 against a throwaway server with the web app's exact requests
  (read from its own code; Chrome wasn't connected to click through it): Play
  from a point and from the start, Pause, seek, Play/Pause, Stop, audio and
  subtitle changes on all three players (system player, AetherEngine, VLC), a
  show, Shuffle, and a film sent over Live TV and over another film. Not yet
  seen on a real Apple TV. An account sees only its own sessions unless the server
  lets it control others'. Jellyfin only.
- **SDR video in HDR** asks tvOS for HDR10 at the film's own frame rate; seen
  giving the brighter picture on two Apple TVs. Off by default.
- **Recaps and previews** need the server to mark them (Jellyfin's Recap and
  Preview segments; Intro Skipper doesn't). Offered by default.
- **Trailers**: the server's own (local trailers) play in JellyGoose; otherwise
  the YouTube link from the film's metadata opens the YouTube app, and on the
  Apple TV the button is only there when that app is installed.
- **Theme music** needs theme songs on the server (a `theme.mp3` beside the
  title, or a plugin that fetches them). On by default.
- **Recordings**: the air date comes from the file's name, or the server's
  dates when it has none; the library is asked again each time it's opened.
