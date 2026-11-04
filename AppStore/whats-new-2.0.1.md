# JellyGoose 2.0.1 — App Store copy (all three platforms)

A fix release for 2.0, build 108, prepared 2026-10-29. It carries the fixes from the 2.0 regression run (PR #19, which had
been merged into #18's branch after that branch went into main, so they reached main
with this release's PR instead). Found on iPhone, iPad and Apple TV simulators against
the throwaway server, with a home server read-only; the Mac part found nothing new.

The app's What's New card shows 2.0's on 2.0.1 (`WhatsNew.version` maps 2.0.1 to 2.0),
so someone coming straight from 1.8.1 still sees it, and no one sees it twice.

Promotional text, description, keywords, screenshots and review notes: 2.0's,
unchanged (App Store Connect carries them over to a new version; What's New is set).

## iPhone and iPad — What's New

```
• Fixed: on iPhone, panels for typing (naming a playlist, a message from the Dashboard, renaming a pin or a library, a Seerr address) were wider than the screen and cut off
• Dashboard: Send Message and Stop Playback appear only for the apps that take them, and word of what happened stays on screen long enough to read
• Downloads: an album or audiobook without cover art shows a note or books instead of a broken picture
• New episode alerts: a moment the server couldn't be reached no longer loses the new episodes it would have told you about
```

## Apple TV — What's New

```
• Dashboard: Send Message and Stop Playback can be reached from the tasks below them, and after a message the remote is back on them instead of on a task's Run button
• Dashboard: Send Message and Stop Playback appear only for the apps that take them, and word of what happened stays on screen long enough to read
```

## Mac — What's New

```
• App icon: the icon you pick in Settings, Appearance now appears in the Dock while JellyGoose is open, instead of a message that this Mac doesn't allow it
• Dashboard: Send Message and Stop Playback appear only for the apps that take them, and word of what happened stays on screen long enough to read
• Downloads: an album or audiobook without cover art shows a note or books instead of a broken picture
• New episode alerts: a moment the server couldn't be reached no longer loses the new episodes it would have told you about
```
