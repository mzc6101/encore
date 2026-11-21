# Encore

A now-playing player for the macOS lock screen. While music plays and the Mac is locked, Encore shows the
artwork, synced lyrics and Liquid Glass playback controls, with the system clock, avatar and password field
still in place.

Works with **Apple Music**, **Spotify** and **YouTube Music** (tab or installed web app). Other audio,
like regular YouTube videos, is ignored.

## Features

- Artwork card with a clear Liquid Glass control card: title, live audio waveform, progress, previous /
  play-pause / next, lyrics toggle and favourite.
- Animated album covers where Apple Music has one (looked up from public album pages, no account needed).
- Time-synced lyrics from [LRCLIB](https://lrclib.net), focused on the current line. With lyrics on, the
  player moves left and lyrics show on the right; with none, the player centres.
- Sharp static covers: the YouTube Music page's own artwork, then Apple's catalog, then Deezer's.
- Favourite / like for Apple Music and YouTube Music.
- Fullscreen player from the menu bar icon.
- Light on resources: about 0.1% CPU and ~20 MB in the background; bounded caches.

## Requirements

- macOS 26 or later (Liquid Glass).
- Xcode Command Line Tools (`xcode-select --install`). No Xcode project needed.

## Build

```sh
./build.sh
cp -R Encore.app /Applications/
```

`build.sh` fetches and compiles [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) on first
run, then builds and ad-hoc signs `Encore.app`.

## Permissions

macOS asks for these the first time each is needed:

- **Automation** for Music, Spotify and your browser (track info, controls, favourite, YouTube Music artwork).
- **Audio capture** for the live waveform. Levels are computed in memory; nothing is recorded or stored.

For YouTube Music in a browser, turn on the browser's **Allow JavaScript from Apple Events**
(Chrome: View > Developer). Without it Encore still works, but the favourite button and YouTube Music's own
artwork are unavailable.

## Privacy

Encore has no accounts, analytics or servers. Network requests go only to LRCLIB (lyrics), the iTunes Search
API and public Apple Music album pages (artwork), and Deezer's public search API (artwork fallback).

## Notes

- The lock-screen overlay, now-playing access and some styling rely on private macOS APIs. A macOS update can
  break them; Encore falls back where it can.
- Not affiliated with Apple, Google, Spotify, Deezer or LRCLIB. All trademarks belong to their owners.

## Debugging

`ENCORE_DEBUG_LOCK=1 /Applications/Encore.app/Contents/MacOS/Encore` shows the lock-screen layout in a normal
window, without locking.

## Credits

- [mediaremote-adapter](https://github.com/ungive/mediaremote-adapter) by Jonas van den Berg (BSD-3-Clause),
  bundled in the app with its license.
- Lyrics by [LRCLIB](https://lrclib.net).

## License

MIT, see [LICENSE](LICENSE).
