# mac-now-playing

A macOS companion for whatever you're playing. It reads the system's now-playing
state (track, artist, live position) from MediaRemote and builds two features on it:

- **Synced-lyrics overlay**: a transparent, click-through karaoke overlay at the
  bottom of the screen. The current line is bright and sharp, neighbours dim and
  recede, and lines spring upward in time with the song. Hover to make it opaque.
- **Discord Rich Presence**: puts the current track on your Discord profile with
  album art and a live progress bar, for real music only (Spotify, YouTube Music,
  Telegram).

Lyrics come from [LRCLIB](https://lrclib.net) (free, no API key). A menubar item
shows the current track and toggles either feature.

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
with a Developer ID and notarise. Quit it from the menubar status item (the music
note icon), which also shows the current track and a "Show Overlay" toggle.

## Project layout

| File | Role |
|---|---|
| `main.swift` | App bootstrap; transparent borderless floating `NSWindow`, hover polling |
| `NowPlaying.swift` | **The now-playing engine**: MediaRemote `osascript` bridge → `NowPlaying` snapshot |
| `Lyrics.swift` | LRCLIB fetch + `[mm:ss.xx]` LRC parser (lyrics feature) |
| `Artwork.swift` | Cover-art resolver via `curl`: iTunes Search API, then YouTube-thumbnail fallback (Discord feature) |
| `PlayerModel.swift` | Polls now-playing, fetches lyrics, tracks current line (interpolated) |
| `LyricsView.swift` | The SwiftUI karaoke view (blur/opacity gradient + spring scroll) |
| `MenuBar.swift` | Menubar status item: now-playing readout, overlay + Discord toggles, Quit |
| `DiscordRPC.swift` | **Discord Rich Presence**: dependency-free local-IPC client (Discord feature) |

## Implementation notes

A few non-obvious things (see [CLAUDE.md](CLAUDE.md) for the full reasoning):

- **MediaRemote needs `osascript`**: on macOS 15.4+ it only serves now-playing data
  to Apple-signed callers, so the app reads it through an `osascript` bridge.
- **`curl`, not URLSession**: URLSession stalls ~8s under this app's run loop, so the
  lyrics and artwork lookups shell out to `curl`.
- **Discord presence** is gated to real music sources (Spotify, YouTube Music,
  Telegram) and shows album art resolved from iTunes (with a YouTube-thumbnail
  fallback). The source badge needs assets uploaded to the Discord app's Art Assets.

Debug commands: `--now` (current track), `--probe "Artist" "Title" <dur>` (lyrics
lookup), `--discord` (test presence), `--art "Artist" "Title"` (cover resolver).

## Next steps

- Reposition/drag, pick alternate LRCLIB version, word-level highlighting, Genius
  plain-text fallback.
- Consider a tiny on-disk cache so re-playing a track is instant despite LRCLIB lag.

## License

[MIT](LICENSE).
