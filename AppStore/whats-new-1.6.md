# JellyGoose 1.6 — App Store copy (Apple TV)

For the Apple TV's 1.6 version. 1.5 went live on 2026-10-13; 1.6 is everything
built since (builds 58 to 81 and the fixes before the archive). The description
in `listing.md` gains Multiview, Watch Together, profiles and the rest of Live
TV's new parts; the review notes in `review-notes.md` say what the demo server
shows of it. Keywords are 1.4's and 1.5's.

## What's New — 1598 / 4000

```
• Multiview: up to four Live TV channels on the screen at once, two side by side or four filling it. Press Up while a channel fills the screen and choose Multiview at the foot of the list. The sound follows the highlight, and Select changes, adds or removes a channel
• Watch Together: start a group or join one from the menu, then play something, and it plays for everyone in step, each on their own screen. A pause or a skip is everyone's. It's Jellyfin's SyncPlay, so someone on the web player can join in too
• A profile for everyone: JellyGoose follows whoever is chosen on the Apple TV, each with their own sign-in, Continue Watching and settings. Someone new picks their face once
• Watch from the start: a programme your server is recording can be watched from its beginning while it's still on
• Commercials: where your server marks the breaks in a recording (a Comskip plugin does), they're drawn on the timeline and Skip Commercials is offered at each one. A switch in Settings skips them without asking, with Undo Skip for a mark that was wrong
• Search finds what's on: programmes in the TV listings, with every time they're showing, to watch or record
• Sleep timer: stop after 15 minutes to an hour and a half, or when the film, episode or programme ends
• Live TV: a strip of channels under the card of what's on, to look along without tuning; the TV switched to each channel's frame rate; a rerun's season, episode and first air date
• Recordings wear their show's artwork and logo, or the guide's picture where your library hasn't the show, and are filed by the day they were made
```

The app's own What's New card (`WhatsNew.items`, "1.6") has six items in all
nine languages on the Apple TV (Multiview, a profile for everyone, Watch
Together, watching from the start, skipping commercials, the sleep timer). An
iPhone or iPad gets CarPlay in place of Multiview and profiles, for when the
iPhone's version carries 1.6.

## Promotional text — 129 / 170

```
New in 1.6: up to four Live TV channels at once, Watch Together with friends in step, and a profile for everyone on the Apple TV.
```

## What the store text leans on

Each of these is a claim someone can check:

- **Multiview** is the Apple TV's only. Each picture is a tuner; a channel the
  server can't give (every tuner in use) says so in its place. Up to four, from
  the full screen's Up list. Seen working on two Apple TVs (the sound followed
  the highlight from build 79).
- **Watch Together** is Jellyfin's SyncPlay. The account needs SyncPlay allowed
  on the server (Jellyfin's default). Closing the player leaves the group; the
  film ending keeps the device in it. Tested between two simulators against a
  throwaway server: pictures three frames apart, pause and seek exact. Not tried
  against the web player.
- **A profile for everyone** is tvOS's runs-as-current-user. An existing install
  keeps its sign-in on updating (seen on a real Apple TV). A second Apple TV person opening
  the app has not been seen on a real TV.
- **Watch from the start** reads the recording's file as the server writes it;
  only for a programme the server is recording.
- **Commercials** need the server to mark them (Comskip Commercial Segments
  plugin, or any that writes Commercial segments). The marks are only as good as
  the detector: right on ABC and FOX in Sam's tests, wrong on one news programme.
  Offered by default; skipped automatically only by the switch.
- **Search** asks the listings by name (`LiveTvProgram`), one card a programme.
- **Sleep timer** lengths are 15, 30, 45, 60 and 90 minutes, and When This Ends.
- **Frame rate** switching needs Match Frame Rate on in the Apple TV's settings.
- **Recordings' artwork**: the library's show where one has the same name, else
  the guide's picture; filed by day from the date in the file's name.
