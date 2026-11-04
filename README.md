# JellyGoose

A native Jellyfin and Emby client for Apple TV, iPhone, iPad and Mac (with CarPlay),
built with SwiftUI. Design inspired by [Plezy](https://plezy.app/): dark, poster-forward
UI with clean shelves and no clutter.

On the [App Store](https://apps.apple.com/app/jellygoose/id6814667375): free to try,
with a one-time unlock; no ads, no subscription, no accounts. Published by Goosehouse LLC as `com.goosehouse.jellygoose`. Site and privacy policy:
[jellygoose.app](https://jellygoose.app). What the App Store needs is in
[`AppStore/`](AppStore/README.md).

## Features

- **Connecting**: type an address (HTTPS is tried before HTTP, port 8096 is assumed,
  and the app says when a connection isn't encrypted), sign in with a password or
  **Quick Connect**, and pick from servers signed in to before
- **Home**: hero banner, Continue Watching, Next Up, Recently Added per library
- **Libraries**: poster grids with sort and filter chips; any filtered view can be
  pinned to the menu and renamed, and the menu's rows rearranged. Films, shows
  and mixed libraries as posters; home videos and music videos as wide stills
  that play when chosen. Collections, playlists and favourites have sections of
  their own
- **Details**: backdrop hero, format badges read from the file (resolution, HDR,
  codecs, audio layout, bitrate), seasons and episodes, cast with photos, similar
  titles, and extras (trailers, behind the scenes) kept beside a film. A film kept
  in more than one version can be played in either
- **People**: open anyone in the cast to see what else of theirs is in the library
- **Long-press menus**: play, play from the beginning, mark watched, favourite,
  put a film on the watchlist, or remove from Continue Watching
- **Watchlist**: films marked to be watched, in a section of their own that's
  there while there's anything on it; watching one takes it off
- **Search** across films and shows, with a row each for the collections and
  the people the words turn up; no episodes, which are found through their show
- **Requests**: with a Seerr (Jellyseerr, as it was) beside the Jellyfin server,
  ask for films and shows the library doesn't have, on screens laid out as
  Seerr's own are: Discover's rows (trending, popular and upcoming, genres,
  studios and networks) and a search; a title's page with where it stands, its
  facts, its cast and what's like it; a request panel with a show's seasons to
  tick and, for those allowed, the server, quality profile and folder; and the
  list of requests, to approve, decline, retry, cancel or delete. A Seerr on the
  server's own machine is found by itself and offered in the menu; signing in is
  with the Jellyfin account by Quick Connect, with no password to type
- **Top Shelf**: Continue Watching and Next Up on the Apple TV home screen, deep-linking back in
- **Settings**: six colour schemes (including true black), six app icons, playback
  and subtitle preferences saved to the Jellyfin account, how subtitles look
  (size, colour, a background behind them, how high they sit, with a preview
  of each choice), and library admin for administrators: add, rename and
  remove libraries and folders, scan, refresh metadata

## Playback

Two engines, chosen per file:

- **AVPlayer** for H.264 and HEVC. Direct play when the container allows it,
  otherwise the server repackages the file as HLS, copying the video rather than
  re-encoding it where it can. HDR, Dolby Vision, frame-rate and dynamic-range
  matching all come from AVKit.
- **VLC** ([VLCKit](https://code.videolan.org/videolan/VLCKit) 3.6) for everything
  AVPlayer can't decode: AV1, VP9, MPEG-2/4, DTS, TrueHD, and image subtitles such as
  PGS. It plays the original file, so the server never transcodes.

Both engines get: resume from the saved position, progress reported to the server,
audio and subtitle track choice (including subtitle files beside a film), chapters,
trickplay thumbnails while scrubbing, skip intro and credits (from the server's media
segments, the Intro Skipper plugin, or chapter names), and an Up Next card for the
following episode. Either skip can be taken without asking, a setting apiece:
an intro as it starts, and the credits straight on to the next episode. Credits
only guessed at from the shape of the chapters stay an offer.

A Stats button in the controls puts a panel in the corner of the picture and
leaves it there: which of the three players has the film, whether the server
is passing it on as it is, repackaging it or converting it and why, what the
file is, and how the stream is holding up (bitrate, buffer, dropped frames).

Subtitles can be looked for on the internet from the foot of the Subtitles menu,
where the server has a provider for them (Open Subtitles, with an account) and
lets the account: a list in the language asked for, the ones timed to the very
file first, and the one chosen fetched by the server, kept with the film and
put on without the film starting again.

## Building

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
xcodegen generate        # regenerate GooseTV.xcodeproj after adding/removing files
open GooseTV.xcodeproj   # build & run on Apple TV simulator or device
```

The project file is generated from `project.yml`; don't edit the `.xcodeproj` by hand.
The version and build number live there too: bump `CURRENT_PROJECT_VERSION` for every
App Store upload.

Install **Release** builds on a real Apple TV when judging how the app feels. Debug
SwiftUI on tvOS is much slower and misrepresents it.

In Debug builds, `GOOSETV_SERVER`, `GOOSETV_USER` and `GOOSETV_PASS` sign in at launch,
`GOOSETV_TAB` opens a section, and `GOOSETV_ITEM` opens an item's page. They are
compiled out of Release.

## Project layout

```
GooseTV/
  App/        entry point, root routing, menu
  Core/       Jellyfin API client, models, session state, device profiles, deep links
  UI/         themes + reusable components (poster cards, shelves, badges)
  Screens/    setup, sign-in, home, libraries, detail, person, search, settings
  Player/     AVPlayer and VLC players, track and chapter choosers, display criteria
  Resources/  Figtree font and bundled licences
TopShelf/     the Top Shelf extension, which compiles the Core files it needs
AppStore/     listing copy, review notes, screenshots
site/         jellygoose.app (Cloudflare)
Signing/      entitlements for the app and the extension
```

## Notes

- `Info.plist` allows local networking and arbitrary HTTP loads, because most home
  Jellyfin servers run plain HTTP and the app has no fixed domain. The reasoning given
  to App Review is in `AppStore/review-notes.md`.
- The access token is kept in a keychain group shared with the Top Shelf extension.
- The code also connects to Emby servers, but that has only been tried against a
  mock, so neither the app nor the listing advertises it yet.

## License

JellyGoose is source-available under the [Functional Source License, Version 1.1,
MIT Future License](LICENSE.md) (FSL-1.1-MIT): use it, read it, change it and build it
for yourself, but not to offer a competing product. Each release becomes MIT two years
after it's published. Copyright 2026 Goosehouse LLC.

The libraries it ships keep their own licences; see `ThirdParty/SOURCES.md` and
`GooseTV/Resources/Licenses`. The name and the app icons are Goosehouse LLC's and aren't
covered by the license.

## Contributing

Bug reports, fixes and ideas are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md); every
contributor signs the [CLA](CLA.md) once. Security problems go to
[SECURITY.md](SECURITY.md), not a public issue.
