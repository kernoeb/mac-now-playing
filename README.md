# lyrics-overlay (prototype)

A transparent, click-through, always-on-top **karaoke lyrics overlay** for macOS.
Shows the currently-playing track's synced lyrics at the bottom of the screen:
current line bright & sharp, neighbouring lines smaller / dimmer / blurrier,
springing upward as the song plays. Hover over it to make it fully opaque.

- **Now playing**: macOS MediaRemote, queried via a JXA `osascript` bridge
  (works on 15.4+, where native framework linking is gated behind a private
  entitlement).
- **Lyrics**: [LRCLIB](https://lrclib.net) — free, no API key, time-synced LRC.
- **No Discord, no Genius** (yet).

## Run

```sh
swift run        # builds and launches the overlay (no Dock icon)
swift test       # run the unit tests
```

Play something in YouTube Music / Apple Music / etc. and the lyrics appear.
Quit from the terminal with Ctrl-C.

## Build a release app

```sh
./build-app.sh   # → LyricsOverlay.app (optimised, ad-hoc signed)
open LyricsOverlay.app
```

Produces a double-clickable `LyricsOverlay.app` (`LSUIElement`, so no Dock icon).
It's ad-hoc signed for local use — for distribution to other Macs you'd sign
with a Developer ID and notarise. Quit it via Activity Monitor (a menubar quit
item is a planned addition).

## Project layout

| File | Role |
|---|---|
| `main.swift` | App bootstrap; transparent borderless floating `NSWindow`, hover polling |
| `NowPlaying.swift` | MediaRemote JXA bridge → `NowPlaying` snapshot |
| `Lyrics.swift` | LRCLIB fetch + `[mm:ss.xx]` LRC parser |
| `PlayerModel.swift` | Polls now-playing, fetches lyrics, tracks current line (interpolated) |
| `LyricsView.swift` | The SwiftUI karaoke view (blur/opacity gradient + spring scroll) |

## Implementation notes (hard-won)

- **MediaRemote**: native linking is blocked by Apple's 15.4+ entitlement; the JXA
  `osascript` bridge is the deliberate workaround. This relies on a **private,
  undocumented Apple framework** — it's ineligible for the App Store and may break on
  any macOS update.
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
- Debug: `LyricsOverlay --probe "Artist" "Title" <duration>` fetches + prints, exits.

## Next steps

- Menubar toggle, reposition/drag, pick alternate LRCLIB version, word-level
  highlighting, Genius plain-text fallback, Discord RPC.
- Consider a tiny on-disk cache so re-playing a track is instant despite LRCLIB lag.

## License

[MIT](LICENSE).
