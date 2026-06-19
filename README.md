# mac-now-playing

A macOS companion for whatever you're playing. The reusable core reads macOS's
now-playing state (track, artist, live playback position) from MediaRemote; that
engine powers the features built on top of it.

**Feature #1 — synced-lyrics overlay.** A transparent, click-through,
always-on-top karaoke overlay at the bottom of the screen: current line bright &
sharp, neighbours smaller / dimmer / blurrier, springing upward as the song
plays. Hover over it to make it fully opaque.

- **Now playing**: macOS MediaRemote, queried via a JXA `osascript` bridge
  (on 15.4+ MediaRemote only serves now-playing data to Apple-signed callers, so
  a third-party app has to borrow the privilege of a platform binary — see notes).
- **Lyrics**: [LRCLIB](https://lrclib.net) — free, no API key, time-synced LRC.
- **Planned**: Discord Rich Presence, menubar now-playing readout, Genius
  plain-text fallback — all on the same now-playing engine.

## Run

```sh
swift run        # builds and launches the overlay (no Dock icon)
swift test       # run the unit tests
```

Play something in YouTube Music / Apple Music / etc. and the lyrics appear.
Quit from the terminal with Ctrl-C.

## Build a release app

```sh
./build-app.sh   # → MacNowPlaying.app (optimised, ad-hoc signed)
open MacNowPlaying.app
```

Produces a double-clickable `MacNowPlaying.app` (`LSUIElement`, so no Dock icon).
It's ad-hoc signed for local use — for distribution to other Macs you'd sign
with a Developer ID and notarise. Quit it via Activity Monitor (a menubar quit
item is a planned addition).

## Project layout

| File | Role |
|---|---|
| `main.swift` | App bootstrap; transparent borderless floating `NSWindow`, hover polling |
| `NowPlaying.swift` | **The now-playing engine**: MediaRemote `osascript` bridge → `NowPlaying` snapshot |
| `Lyrics.swift` | LRCLIB fetch + `[mm:ss.xx]` LRC parser (lyrics feature) |
| `PlayerModel.swift` | Polls now-playing, fetches lyrics, tracks current line (interpolated) |
| `LyricsView.swift` | The SwiftUI karaoke view (blur/opacity gradient + spring scroll) |

## Implementation notes (hard-won)

- **MediaRemote / why `osascript`** (verified on 15.6, not assumed): as of macOS
  15.4 MediaRemote only returns now-playing data to **Apple-signed** callers —
  platform binaries like `/usr/bin/osascript`, or Apple's own team-signed tools. A
  third-party app is denied no matter how it's signed: tested ad-hoc *and*
  Apple-Development-signed builds, both got nil from the `MRNowPlayingRequest` ObjC
  accessor and an empty dict from the async `MRMediaRemoteGetNowPlayingInfo` C
  function. So the app shells out to `osascript` (a platform binary that *is*
  allowed) running the very same `MRNowPlayingRequest` class. This relies on a
  **private, undocumented Apple framework** — ineligible for the App Store, and may
  break on any macOS update.
- **Playback position**: MediaRemote's `ElapsedTime` does NOT tick on its own
  (especially for web players like YT Music) — it's a sample taken at `Timestamp`.
  Live position = `elapsed + (now − Timestamp) × rate`. We capture `Timestamp`
  (an `NSDate`) from the bridge and project forward; otherwise the highlight freezes.
- **Networking via `curl`, not URLSession**: under this app's AppKit run loop,
  `URLSession` (async, completion, or semaphore — all variants) stalls for ~8s per
  request; the same `curl` subprocess returns normally. So `Lyrics.swift` shells out
  to `curl`, mirroring the `osascript` pattern. Run it on a background queue.
- **LRCLIB latency is variable** (sometimes ~1s, sometimes ~7s server-side). For each
  lookup we fire `/api/get` (LRCLIB's canonical, correctly-timed match) and
  `/api/search` (ranked alternates) **concurrently**, then use the canonical — unless
  the user prefers romanised lyrics and a romanised search candidate's timing agrees
  (see `preferRomanized`). A fresh track shows a small loading indicator (three dots)
  until the fetch returns.
- Debug: `MacNowPlaying --now` prints the current now-playing read and exits;
  `MacNowPlaying --probe "Artist" "Title" <duration>` fetches lyrics + prints, exits.

## Next steps

- **Discord Rich Presence** and a **menubar now-playing readout** — the first
  features beyond the overlay to reuse the now-playing engine directly.
- Menubar toggle/quit, reposition/drag, pick alternate LRCLIB version, word-level
  highlighting, Genius plain-text fallback.
- Consider a tiny on-disk cache so re-playing a track is instant despite LRCLIB lag.

## License

[MIT](LICENSE).
