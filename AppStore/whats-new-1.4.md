# JellyGoose 1.4 — App Store copy (Apple TV)

For the Apple TV's 1.4 version (build 49 or later; builds 42 and 43 could
freeze on leaving Live TV). The description has a paragraph on Live TV, in
`listing.md`; the review notes say what 1.4 adds and that the demo server
shows none of the television, in `review-notes.md`. The keywords gain Seerr,
as asked for with 1.3 and held over, and Live TV (see `listing.md`). The
screenshots are 1.3's with the Live TV guide third, in place of the
long-press menu.

## What's New — 1448 / 4000

```
• Live TV: where your Jellyfin server has a tuner (an HDHomeRun, for one), its channels get a section of their own. A guide to what's on and what's coming, with the channel you're watching playing beside it; choose what's on to fill the screen, and change channel from there. It opens on the channels you last chose: all, your favourites, news, sport, films or kids
• Recording: set one showing or a whole series to record, from the guide or while you watch, and see everything that's set under Scheduled. For a series, choose which episodes, which channel and what time, and how many to keep
• Delete a recording with a long press on it, or choose several with Select and delete them together
• A long press on a recorded show: change how its series is recorded, or delete every recording of it. On the show's page, a long press on an episode deletes that one
• On Now: a row on Home of what your channels are showing this minute
• Two switches in Settings, under Live TV: one takes Live TV out of the menu on that Apple TV, the other takes On Now off Home
• Home, arranged your way: put its rows in the order you like, or switch any of them off (Settings, Home Screen)
• Search now stands at the top of the menu, above Home. A menu you've put in your own order keeps it
• Fixed: from a row of posters on Home, a press right from the menu could go nowhere
• Fixed: Home could stop answering the remote when you came back to it from another section
```

The app's own What's New card (`WhatsNew.items`, "1.4") has four of these, in
all nine languages: Live TV, recording, On Now and arranging Home. On an
iPhone or iPad it has a fifth, Picture in Picture, which the Apple TV's
version has no part of.

## Promotional text — 151 / 170

```
New in 1.4: Live TV. Your server's channels in a guide with the picture beside it, recording, and what's on now on Home. Plus a Home you can rearrange.
```

## What the store text leans on

Each of these is a claim someone can check, so before the copy is reused:

- **Live TV** is the server's: the section is in the menu only where the
  account's server lists channels, which it does once it has been given a
  tuner and, for the guide, listings. Tried with an HDHomeRun (a FLEX 4K
  over the air, and an emulated one); an IPTV list through Jellyfin hasn't
  been. Emby's Live TV hasn't been tried at all, and the listing claims
  Jellyfin alone.
- **What it won't tune**: ATSC 3.0 channels whose sound is AC-4. Jellyfin
  hangs opening them with the tuner held, so the app asks first what a
  channel is made of and leaves those alone, saying it can't play them.
- **Recording** is offered to accounts the server's owner lets manage Live
  TV. The server does the recording and keeps it, in a Recordings library
  of its own making; where it's kept is set on the server. A series is set
  with the server's own defaults, and four of them can then be changed
  from its row under Scheduled: new episodes only or all, its channel or
  any, around its time or any, and how many are kept. Padding and days
  stay the server's.
- **Deleting a recording** removes its file from the server's disk, after
  asking. It's offered in a library the server records into, to an account
  allowed to delete from it: one recording by its long press, several by
  Select, and a show's whole set by the show's long press, which deletes
  the show from the library and leaves its series set to record. A
  recordings folder that holds other things (another DVR's files, say) has
  those listed and deletable too: the library is the server's to point.
- **Recording Options on a show** is there when the server has a series
  set whose name is the show's title. A show recorded one showing at a
  time, or whose series has since been cancelled, has only the deleting.
- **The guide's last choice of channels** is kept on the device, not the
  list of recordings, and gives way to every channel when nothing fits it.
- **Search first in the menu** is for a menu nobody has rearranged.
- **On Now** needs both switches on (Live TV in the menu, On Now on Home)
  and tunes nothing by being there.
- **Home's rows** are arranged per device, not per account: the order and
  what's off are kept on the Apple TV they were set on.
- **The two fixes** were both in 1.3 and before. A row of posters could be
  the band's row with its first poster wholly under the open menu; and
  Home, made anew on coming back from another section, remembered a card
  far along a row that was no longer in sight.
