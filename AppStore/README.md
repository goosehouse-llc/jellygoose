# Submitting JellyGoose

What to paste where, what is already done in the build, and what is still
yours to do in App Store Connect.

- [`listing.md`](listing.md) — name, subtitle, description, keywords, URLs,
  category, price
- [`review-notes.md`](review-notes.md) — the demo server the reviewer needs, and
  the answers to the questionnaires
- `final/` — ten screenshots at 3840×2160, in upload order, from the real library
- `screenshots/` — everything the capture run produced, kept out of git because
  the test regenerates it

## Decisions already taken

**Free, for this release.** Not because the app isn't worth money, but because
its reliability is unproven outside one house and one server: free turns an
unplayable file into a bug report rather than a refund and a one-star review.
Adding a paid tier later through in-app purchase is straightforward and leaves
existing users untouched; going from free to paid up front is not, so nothing in
the listing promises it will always be free.

**One bundle ID for every platform.** `com.goosehouse.jellygoose`, with no
platform suffix, because Universal Purchase requires the same identifier across
tvOS, iOS, iPadOS and macOS. Create the tvOS app now; use **Add Platform** on
the same record when the others exist.

**Goosehouse LLC, not a person.** The team was always the company; the
identifier now matches, and the bundle carries the company's copyright line. A
distribution build signs as `Apple Distribution: Goosehouse LLC (579BSQT6J4)`.

## Already handled in the build

- `PrivacyInfo.xcprivacy` — no tracking, no collected data, UserDefaults
  declared under reason CA92.1. Without this the upload is refused.
- `ITSAppUsesNonExemptEncryption` — answered in the plist, so uploads don't stop
  to ask.
- The access token lives in the keychain, not in UserDefaults.
- The debug sign-in and launch hooks are compiled out of release builds.
- `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` come from `project.yml`;
  bump `CURRENT_PROJECT_VERSION` for every upload or the build is rejected as a
  duplicate.
- Licences for VLCKit (LGPL) and Figtree (OFL) are bundled and readable in
  Settings → About → Licences.

## Still to do, in order

1. **Create the app record** — Apps → + → New App, with the four fields at the
   top of `listing.md`.
2. **Fill in the listing** from `listing.md`, and upload `final/` in order.
3. **Fill in App Review Information** from `review-notes.md`, including the
   demo server. This is the step that prevents the most likely rejection.
4. **Archive and upload** — Product → Archive in Xcode, then Distribute App →
   App Store Connect. The archive signs as Goosehouse LLC.
5. **Answer the questionnaires** — privacy, content rights, age rating, all in
   `review-notes.md`.
6. **Submit.**

## Regenerating the screenshots

The capture is a UI test, kept in `UITests/`: `StoreShotsUITests` takes the
ten shots, and `QuickConnectUITests` signs a simulator in to the server first.
They need a UI-testing target, which the app's own project doesn't have: generate
one with XcodeGen from a copy of `project.yml` with a `bundle.ui-testing` target
added whose sources are `UITests/` and whose `TEST_TARGET_NAME` is `GooseTV`.

1. Run `QuickConnectUITests` on a clean Apple TV 4K simulator. It opens the
   server's sign-in screen and asks for a Quick Connect code; approve it from
   the Jellyfin dashboard (or the API) as the account to photograph. The set in
   `final/` uses the JellyGoose profile.
2. Run `StoreShotsUITests` on the same simulator. The shots land in
   `/tmp/jellygoose-shots/` at 3840×2160; copy them into `final/`.

The library and film IDs in the test are the real server's (Movies, Movies4k, The Matrix
Resurrections, Top Gun: Maverick). The account needs setting up for three of the
shots, and putting back afterwards:

- **Home, the menu and the long-press** (`test2Home`): Continue Watching reads Bluey,
  13 Hours, The Dark Knight, Back to the Future, Aliens. Bluey and 13 Hours are in
  progress already; the 4K copies of the other three get a position (55%, 38%, 28%)
  and last-played times an hour apart, and 13 Hours a last-played time just after
  Bluey's. Back to the Future's position comes off again for the long-press shot, so
  its menu offers Play, Mark as Watched and Add to Favourites.
- **Maverick's page** (`test5Maverick`): Maverick unwatched, and not in progress, so
  its page offers Play.
- **The player** (`test3Player`): Maverick resumed from 1:57:36, which the test
  pauses at 1:57:59 on the close-up. Take it last: playing it moves the position.

Take the library shots before the Continue Watching setup, or the Movies4k grid
shows progress bars. On a fresh simulator, close the What's New card first (or
set `whatsNew.seenVersion`).

Worth knowing: Apple asks you to hold the rights to third-party content shown in
screenshots, and these are commercial films. Every media client's screenshots
show somebody's library and this is routine, but it is a considered risk rather
than an oversight. A conservative alternative is a library of Blender's open
movies (CC-BY) — attractive, animated, and licensed for exactly this.
