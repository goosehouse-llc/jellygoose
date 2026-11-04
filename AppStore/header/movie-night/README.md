# Movie Night header (1.8)

Sam, 2026-10-26: "make me an app store header that shows the on screen header
from the appleTV with the Movie Night app theme", then "put it on both 1.8
submissions".

`header-tv-3840x1646.png` is the Movie Night icon's room (its goose, couch,
screen glow and beam, from `Tools/render-icon.swift`'s shapes), with a large
television showing JellyGoose's Home as captured from the Apple TV app
(`home.png`, 3840 x 2160, the 4K simulator). The films on it are made up, so
no real film is on the store page: Lantern Bay heads the screen, and City of
Small Hours, Paper Planets, Glasswater and Red Canyon Run fill Continue
Watching.

- `header.html`: the header, drawn at 2400 x 1029 CSS px at 2x, then scaled to
  3840 x 1646 (`sips -z 1646 3840`).
- `films/film-art.html`: each film's backdrop and poster
  (`?film=lantern&w=1920&h=1080`, or `&poster=1&w=1000&h=1500`).
- `films/logo.swift`: the Lantern Bay title logo.
- `films/make_films.py`: puts the five films in a test server's Films library,
  with their details (NFO) and a still-frame video of each film's length, and
  marks them part-watched so they make up Continue Watching.

On App Store Connect: asset library image `ac800019-62f9-826f-8009-066214e6cc65`
(3840 x 1646 header spec), placed as the product page header on the Apple TV's
1.8 and the iPhone and iPad's 1.8 (en-US), in place of the headers copied from
1.7.1, which stay on the live versions. It goes to review with each version.
