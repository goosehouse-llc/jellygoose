# JellyGoose 1.8 — App Store copy (Apple TV)

For the Apple TV's 1.8 (build 103). 1.7.1 went live on both platforms on
2026-10-26; 1.8 is everything built since (music, audiobooks, video
playlists and collections, Coming Soon, each show's tracks remembered,
Dialogue Boost, pins on Home, iCloud Sync, Plugins). The description is in
`listing.md`, the review notes in `review-notes.md`; keywords stay as they
are live (Sam changed "home theater" to "IPTV" in App Store Connect).

## What's New — 1350 / 4000

```
• Music: your server's albums, artists, songs and playlists, with lyrics, Up Next, shuffle, repeat and Instant Mix. Make playlists, star favourites, browse by genre, and keep the music playing while you look for something to watch
• Audiobooks: chapter by chapter, at the speed you like, and picked up where you left off
• Playlists and collections: make playlists of films and episodes from their long-press menu, and add films and shows to collections where your account may
• Coming Soon: a row on Home of the episodes still to air for the shows in your library, by the day they air
• Audio and subtitles, show by show: choose them once in an episode and the rest of the show follows
• Dialogue Boost: voices brought forward over music and effects, for films the built-in VLC engine plays and on Live TV
• Pinned views on Home: a library view you've filtered can be a row on Home as well as in the menu
• iCloud Sync: settings, pinned views and each show's choices shared with your other devices, while each keeps its own colour scheme
• Plugins: server administrators can add, update, switch off and remove the server's plugins from Settings, and restart the server
• Series recordings can keep just the latest one, two or three
• A library added on the server appears in the menu without restarting the app, and Evergreen has softer, sage greens
```

The app's own card (`WhatsNew.items`, "1.8") has six items on the Apple TV in
all nine languages: Music, Audiobooks, Playlists and Collections, Audio and
Subtitles Show by Show, iCloud Sync, Plugins. An iPhone or iPad gets Siri and
Shortcuts, Widgets and Keep Downloaded in place of the middle three and
Plugins.

## Promotional text — 141 / 170

```
New in 1.8: your server's music and audiobooks, playlists of films and episodes, each show's audio and subtitles remembered, and iCloud Sync.
```

## What the store text leans on

- **Music** needs a music library on the server; the demo server has one
  (four albums, three playlists, checked 2026-10-26). Lyrics show where the
  server has them.
- **Audiobooks, Coming Soon and collections** need books, episodes with
  future air dates, and collections the account may change. The demo server
  has none of the three.
- **Dialogue Boost** is VLC's equalizer: only for what the built-in VLC
  engine plays (and Live TV); Apple's player and AetherEngine have no sound
  processing. Night Mode was tried and isn't possible in VLCKit.
- **iCloud Sync** is iCloud key-value storage; each device keeps its own
  colour scheme, quality, players, downloads and Live TV switches, and pinned
  views can be kept on one device.
- **Plugins** are installed and run by the server, from its own catalogue;
  the app sends the server's own API calls and downloads no code. Shown to
  Jellyfin administrators only.
