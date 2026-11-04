# App Review information

The likeliest reason a client like this is rejected is that the reviewer opens
it, is asked for a server address, has none, and sees an empty app. That is a
Guideline 2.1 rejection, and the whole of this file exists to prevent it.

## App Review Information panel

Tick **Sign-in required**.

| Field | Value |
|---|---|
| User name | `demo` |
| Password | *(leave empty — the demo server has none; the notes say so)* |
| Contact | your own name, email and phone |

## Notes

```
JellyGoose is a client for Jellyfin and Emby media servers. It has no accounts and no content of its own: it plays what is on a server the user runs, so a server is required to see anything.

For review, please use the Jellyfin project's public demo server:

1. Launch the app. On "Connect to your Jellyfin or Emby server", select the address field and enter:
   demo.jellyfin.org/stable
   No "https://" is needed; demo.jellyfin.org on its own also connects.
2. Press Connect. The sign-in screen for "Stable Demo" appears. Enter user name "demo" and leave the password empty.
3. Press Sign In. The home screen will show films, shows and music that can be browsed and played.

Free trial (Guideline 3.1.1): the app is free to download, and playing needs the free non-consumable "7-day Trial" or the non-consumable "JellyGoose Unlock", shared with the iPhone and iPad app. The first time anything is played, the unlock screen states the trial's length, that playing stops after it, and the unlock's price; select Start Free Trial to go on. Browsing stays free. Restore Purchases is on that screen and in Settings > JellyGoose Unlock.

If the app says it couldn't reach a server, the address was not entered as above; the same server can be opened in a browser at https://demo.jellyfin.org/stable to confirm it is up.

New in 1.8, and what the demo server shows of it:

- Music: the demo server's Music library is in the menu, with albums, artists, songs and playlists. Music plays on while the rest of the app is used; Now Playing is at the top of the menu.
- Playlists of films and episodes: Add to Playlist… in a film's or episode's long-press menu.
- Audiobooks, Coming Soon (episodes still to air) and Add to Collection appear where a server has books, future episodes and collections the account may change. The demo server has none, so they are absent there.
- iCloud Sync (Settings > iCloud Sync) shares the app's own settings between the user's devices through iCloud key-value storage, and can be turned off.
- Plugins (Settings > Plugins) lets the administrator of a Jellyfin server install, update, switch off and remove that server's plugins, from the catalogue the server itself offers, and restart it. The server downloads and runs them; the app downloads and runs no code (Guideline 2.5.2). Only administrators see it; the demo account is not one, so it is absent there, as is library management.

Earlier features that depend on the user's own server, absent on the demo server as intended:

- Live TV (guide, recordings, Multiview, listings in Search) needs a television tuner on the user's server, such as an HDHomeRun; the server tunes and records, and the app has no channels of its own. Up to half an hour of a channel is kept in temporary files so it can be paused, deleted when the channel is left.
- Requests is a front end to Seerr (an open-source request manager) where the user's server has it; the app fetches no media itself.
- Search for Subtitles asks the user's server to search the subtitle provider its owner has set up, for accounts allowed to manage subtitles.
- Skip Intro, Recap, Preview and Credits, trailers and theme music act where a server marks or keeps them.

Also on the demo server: Watch Together (Watch Together > Start a Group in the menu, then play a film; it is Jellyfin's SyncPlay), and Play on TV: with JellyGoose open, sign in as demo at https://demo.jellyfin.org/stable in a browser, choose the cast button, pick the Apple TV (it can be named in Settings > Playback) and play a film; the browser's controls act on it. The app runs as the current Apple TV user (User Management capability), each with their own sign-in and settings.

The app collects no data and contains no advertising or analytics. It communicates only with the servers the user chooses, and with the user's own iCloud for settings while iCloud Sync is on.
```

1.8's (3879 / 4000) leads with what's new and what the demo server
shows of it (music yes; audiobooks, Coming Soon and collections no), and
says the Plugins page is the server's own plugin manager: the server
downloads and runs plugins, the app none (Guideline 2.5.2). The earlier
versions' paragraphs are folded into one list of what needs the user's own
server.

The paragraphs on what's new are there so that nobody goes looking for Live
TV, Requests or the subtitle search on the demo server and concludes they're
missing. 1.7's tells the reviewer how to see Play on TV with nothing but a
browser, since the iPhone's half isn't out yet; 1.6's was cut down to fit
(3,841 of 4,000 characters). 1.3's was cut down to make room for 1.4's (the field holds 4,000
characters): Stats, the subtitle settings, the watchlist and the wider Search
all show on the demo server and need no explaining. Take a paragraph out
again for a version that adds nothing a reviewer couldn't find.

## When a reviewer can't connect

1.2 build 9 was rejected under 2.1 on 2026-10-01 ("unable to sign in"), with a
screenshot of "Couldn't reach a Jellyfin or Emby server at that address" beside
one of the demo server open in Safari at demo.jellyfin.org. The address in the
notes connected; demo.jellyfin.org without "/stable" did not, because the top
of that site only redirects to the server's web pages. Since build 10 the app
follows that redirect, so either form connects, as does an address copied from
a browser.

## If they ask about Requests

Guideline 5.2.3 is the one that could be read against it: apps must not
"facilitate illegal file sharing" or download media from third-party sources.
Clients for Seerr, Radarr and Sonarr are on the store, so there is precedent,
and the answer is what the app does and doesn't do:

```
Requests is a remote control for Seerr, a request-management tool the user runs on their own server. JellyGoose signs in to it with the user's media server account, displays the catalogue Seerr provides, and records a request there for the server's owner to approve or decline. JellyGoose does not search for, download, convert or save any media, and contains no sources of its own. What happens to a request is decided by software the user has installed and configured on their own machine, and the section is absent unless the user's server has it.
```

## If they ask about Live TV

```
Live TV shows the channels of a television tuner that the user has connected to their own Jellyfin server, such as an HDHomeRun receiving free-to-air broadcasts from their own aerial. The server tunes the channel and sends it to the app, exactly as it sends a film from the user's library; recordings are made and stored by that server. JellyGoose contains no channels, streams or listings of its own, connects to no television service, and shows the section only when the user's server reports channels.
```

## If they ask about the subtitle search

```
The search is carried out by the user's own Jellyfin server, through a subtitle provider the server's owner has configured with their own account. JellyGoose sends the request to that server and displays its answer; the subtitle file is saved by the server beside the film, and the app then shows it like any other subtitle the film has. The app contacts no subtitle service itself.
```

## If they ask about the transport security exception

The app declares `NSAllowsArbitraryLoads` alongside `NSAllowsLocalNetworking`.
The answer:

```
JellyGoose connects to a media server the user supplies, so there is no fixed domain to write an exception for. Home servers commonly run plain HTTP on the local network, which NSAllowsLocalNetworking covers; the broader exception is for users who reach their own server over the internet without TLS. The app tries HTTPS before HTTP when an address is typed without a scheme, and tells the user on the sign-in screen when a connection is not encrypted.
```

## Questionnaires

**App Privacy** — "Data is not collected from this app." No tracking, no
third-party SDKs, nothing to declare.

**Content rights** — *Does your app contain, show, or access third-party
content?* → **Yes**, and confirm the rights: the content is the user's own
library on their own server.

**Export compliance** — not asked. `ITSAppUsesNonExemptEncryption` is in the
build, answered as exempt, because the app uses only HTTPS/TLS.

**Age rating** — every category **None**, giving **4+**. The app itself contains
nothing objectionable; what it displays is whatever is in the user's library.
Some media players choose 12+ for that reason, and either is defensible.
