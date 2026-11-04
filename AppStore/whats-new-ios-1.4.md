# JellyGoose 1.4 — App Store copy (iPhone and iPad)

For the iPhone and iPad's 1.4 version (build 50 or later). 1.2.1, their
first version, was taken out of review on 2026-10-11 after nine days'
waiting, and 1.4 went in its place: so 1.4 is the first version these devices
have, and a first version has no What's New (App Store Connect doesn't show
the field). Of what's below, only the promotional text is entered. The
description, keywords, review notes and screenshots are in `listing-ios.md`.

The two What's New texts are kept for reference: the app's next version
will be the first on these devices to have the field.

## What's New, 1.4 alone — 1454 / 4000

```
• Live TV: where your Jellyfin server has a tuner (an HDHomeRun, for one), its channels get a section of their own. A guide to what's on and what's coming, with the channel you're watching playing alongside; choose what's on to fill the screen, and change channel from there. It opens on the channels you last chose: all, your favourites, news, sport, films or kids
• Recording: set one showing or a whole series to record, from the guide or while you watch, and see everything that's set under Scheduled. For a series, choose which episodes, which channel and what time, and how many to keep
• Delete a recording with a long press on it, or choose several with Select and delete them together
• A long press on a recorded show: change how its series is recorded, or delete every recording of it. On the show's page, a long press on an episode deletes that one
• On Now: a row on Home of what your channels are showing this minute
• Two switches in Settings, under Live TV: one takes Live TV out of the menu on that device, the other takes On Now off Home
• Picture in Picture: a button in the player shrinks the film to a corner of the screen while you use the rest of the app. Turn the device on its side to fill the screen again
• Home, arranged your way: put its rows in the order you like, or switch any of them off (Settings, Home Screen)
• Fixed on iPad: a tap on a section's icon at the side now goes to its page. It used to open the menu instead
```

## What's New, everything since 1.2.1 — 3188 / 4000

```
• Live TV: where your Jellyfin server has a tuner (an HDHomeRun, for one), its channels get a section of their own. A guide to what's on and what's coming, with the channel you're watching playing alongside; choose what's on to fill the screen, and change channel from there. It opens on the channels you last chose: all, your favourites, news, sport, films or kids
• Recording: set one showing or a whole series to record, from the guide or while you watch, and see everything that's set under Scheduled. For a series, choose which episodes, which channel and what time, and how many to keep
• Delete a recording with a long press on it, or choose several with Select and delete them together
• A long press on a recorded show: change how its series is recorded, or delete every recording of it. On the show's page, a long press on an episode deletes that one
• On Now: a row on Home of what your channels are showing this minute
• Two switches in Settings, under Live TV: one takes Live TV out of the menu on that device, the other takes On Now off Home
• Picture in Picture: a button in the player shrinks the film to a corner of the screen while you use the rest of the app. Turn the device on its side to fill the screen again
• Home, arranged your way: put its rows in the order you like, or switch any of them off (Settings, Home Screen)
• Fixed on iPad: a tap on a section's icon at the side now goes to its page. It used to open the menu instead
• Requests: with Seerr beside your Jellyfin server, see what's trending, popular and coming soon, by genre, studio and network, and ask for films and shows from wherever you are. The section appears in the menu by itself when your server has one
• Intros and credits can be skipped for you: two switches in Settings, under Playback. Credits go straight on to the next episode
• Search the internet for subtitles from the player's Subtitles menu, through your server's own subtitle provider. The one you pick appears without the film restarting
• Subtitles in a colour, on a background and at a height of your choosing, with a preview as you choose (Settings, Subtitles)
• A watchlist for films: add one from its page or with a long press, and watching it takes it off
• Search finds people and collections as well as films and shows
• Home videos, music videos and mixed libraries now appear with the rest
• A Stats button in the player shows which player has the film, whether your server is converting it and why, and how the stream is holding up
• Downloads: one that breaks off carries on from where it stopped, and a banner tells you when one finishes or fails
• A sixth colour scheme: Evergreen, green and teal over deep pine. It's in Settings, under Appearance
• The Libraries page shows each library as a tile of its own artwork
• Up Next now comes up as the credits start on many more episodes: the ones whose files mark their credits without naming them
• In a TV library, Episodes with Favourites lists the episodes of your favourite shows. It used to come up empty
• Skip Intro no longer stays up for a whole episode on files that mark only where the intro begins
• Collections and playlists show how many items they hold
```

## Promotional text — 142 / 170

For a version that is the first on these devices, or the first to have Live
TV there:

```
Now on iPhone and iPad: your Jellyfin library in your pocket, downloads for when your server is out of reach, and Live TV from your own tuner.
```

## What it leans on

As for the Apple TV (`whats-new-1.4.md`), and on a phone or tablet besides:

- **Live TV by touch** has the picture above the guide on an iPhone and in
  the corner beside it on an iPad. Watched on a real iPhone with a real
  tuner; the iPad's has only been seen in the simulator.
- **Picture in Picture by its button** is for films the Apple player or the
  MKV engine plays. What the VLC engine plays (AV1, VP9, MPEG-2 and the
  like) has no button, and Live TV has none. It has been tried on an iPad
  simulator only: an iPhone simulator has no Picture in Picture at all, and
  no real device had been tried when this was written. Known and not yet
  put right: an episode playing small still counts down to the next one
  unseen and then takes the screen back with it.
- **The two Live TV switches** and **Home's arrangement** are kept on the
  device they were set on, not with the account.
- **Search first in the menu** is the iPad's menu and the iPhone's full
  one, for a menu nobody has rearranged. The iPhone's bar along the bottom
  still begins with Home.
- **The iPad fix** was in 1.2.1: only the lines of a section's icon took a
  tap, so most taps on one opened the menu. Tried in the simulator.
- **Recording and deleting** have been tried by touch against a throwaway
  server with an emulated tuner, never on a server with recordings worth
  keeping.
