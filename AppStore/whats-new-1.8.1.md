# JellyGoose 1.8.1 — App Store copy (both platforms)

A fix release for 1.8 (released 2026-10-26), build 104. A user reported (2026-10-27,
through Sam) that after the update their TV library listed every episode of all
122 shows on its own card, no longer grouped by show and season.

The cause: Jellyfin counts a library among its Live TV recording folders when the
series (or film) recording path is inside it, as many set it up so recorded shows sit
among the rest. Since 1.7, a recordings library is listed a recording at a time, filed
by the day it was made; so the whole TV library became every episode on its own card.
From 1.8.1 a library of shows or films is listed by its titles whatever the server
records into it (`MediaBrowserClient.liveRecordingFolders`); the server's own
Recordings library keeps its by-day list. Reproduced and checked on the throwaway
server (series recording path set to its Shows folder, then put back).

A library viewed while it was wrong keeps the Recently Added order it was given then,
until Title is chosen or Clear pressed.

## What's New

```
• Fixed: where the server saves Live TV recordings into the TV library, that library listed every episode on its own instead of grouping them by show and season. Shows are back as they were.
```

The app's What's New card shows 1.8's on 1.8.1 (`WhatsNew.version` maps 1.8.1 to 1.8),
so someone coming straight from 1.7.1 still sees it, and no one sees it twice.

Promotional text: 1.8's, unchanged.
