# Third-party source code

The exact source of every library the app ships under a licence that asks for
its source to stay available (LGPL), and of what they are built from. Kept here
so it doesn't depend on the upstream repositories staying up: the archives are
attached to the release
[`sources-2026-10-01`](https://github.com/goosehouse-llc/jellygoose/releases/tag/sources-2026-10-01)
on this repository, with `SHA256SUMS`. Anyone asking for a library's source
under its licence gets the matching archive.

Each is an archive of the upstream tag or commit named, as downloaded on
2026-10-01. Figtree (OFL) asks for no source and isn't here.

| Component | What it is in the app | Licence | Archive | Upstream | SHA-256 |
|---|---|---|---|---|---|
| AetherEngine 7.24.0 | Plays MKV and picture subtitles on the Apple TV (Swift package, compiled in) | LGPL-3.0 with an App Store / DRM exception | `AetherEngine-7.24.0.tar.gz` | [source](https://github.com/superuser404notfound/AetherEngine/tree/7.24.0) | `a092966747527cd3…` |
| FFmpegBuild 3.6.0 | Build scripts and local FFmpeg patches for AetherEngine's frameworks | LGPL-2.1 (scripts and patches) | `FFmpegBuild-3.6.0.tar.gz` | [source](https://github.com/superuser404notfound/FFmpegBuild/tree/3.6.0) | `65d49b3b4d30b3af…` |
| FFmpeg n8.1.3 | libavcodec, libavformat, libavutil, libswresample, libswscale, libavfilter | LGPL-2.1-or-later (built without GPL parts) | `FFmpeg-n8.1.3.tar.gz` | [source](https://github.com/FFmpeg/FFmpeg/tree/n8.1.3) | `09f990289327d3eb…` |
| dav1d 1.5.4 | AV1 decoder in AetherEngine's frameworks | BSD-2-Clause | `dav1d-1.5.4.tar.gz` | [source](https://code.videolan.org/videolan/dav1d/-/tree/1.5.4) | `a1d5b63d2d38ec9b…` |
| zimg release-3.0.6 | Scaling in AetherEngine's frameworks (with its googletest submodule) | WTFPL | `zimg-release-3.0.6.tar.gz` | [source](https://github.com/sekrit-twc/zimg/tree/release-3.0.6) | `e935ac37f7522613…` |
| libzvbi v0.2.45 | Teletext in AetherEngine's frameworks (GPL files removed by FFmpegBuild) | LGPL-2.0-or-later, ure.c MIT | `zvbi-v0.2.45.tar.gz` | [source](https://github.com/zapping-vbi/zvbi/tree/v0.2.45) | `e6c954fde2a5a635…` |
| LibDovi 2.1.0 | Packaging of libdovi for AetherEngine | MIT | `LibDovi-2.1.0.tar.gz` | [source](https://github.com/superuser404notfound/LibDovi/tree/2.1.0) | `4e09d1981fe1e4f3…` |
| dovi_tool libdovi-3.4.0 | libdovi (the dolby_vision crate) itself | MIT (of MIT / Apache-2.0) | `dovi_tool-libdovi-3.4.0.tar.gz` | [source](https://github.com/quietvoid/dovi_tool/tree/libdovi-3.4.0) | `8eac4d1c3134f53e…` |
| VLCKit 3.6.0 (c73b779f) | VLC's framework for Apple platforms | LGPL-2.1-or-later | `VLCKit-3.6.0.tar.gz` | [source](https://code.videolan.org/videolan/VLCKit/-/tree/3.6.0) | `eb5813d3dbddfb1d…` |
| VLC 3.0.21 (dd8bfdba) | libvlc inside VLCKit 3.6.0, at the commit TVVLCKit-3.6.0-c73b779f-dd8bfdba was built from | LGPL-2.1-or-later | `vlc-dd8bfdbabe8ae3974ca3864ad3125879f523e3a2.tar.gz` | [source](https://code.videolan.org/videolan/vlc/-/tree/dd8bfdbabe8ae3974ca3864ad3125879f523e3a2) | `b933376dd606e5a2…` |
| vlckit-spm 3.6.0 | The Swift package the app takes VLCKit from | LGPL-2.1 (packaging) | `vlckit-spm-3.6.0.tar.gz` | [source](https://github.com/tylerjonesio/vlckit-spm/tree/3.6.0) | `782ecaa576a7d4e3…` |

## When a library changes

A new version of any of these (a bump in `project.yml`, or AetherEngine's
pins on FFmpegBuild and LibDovi moving with it) needs its source archived the
same way before that build ships: download the tag, check it, add it to a new
`sources-<date>` release, and update this table and the version in the
Licences page's credit.
