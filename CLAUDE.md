# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
swift build                 # debug build
swift build -c release      # optimised build
swift run                   # build + launch the overlay (no Dock icon; Ctrl-C to quit)
swift test                  # run the test suite (XCTest)
swift test --filter testParsesBasicTimestamps   # run a single test by method name

./build-app.sh              # → MacNowPlaying.app (release, ad-hoc signed)

# Debug entry points (compiled into the app, see main.swift):
.build/debug/MacNowPlaying --now                          # print the current now-playing read, exit
.build/debug/MacNowPlaying --probe "Artist" "Title" 200   # fetch + print lyrics for a track, exit
```

There is no linter configured. The app is a `LSUIElement` agent (no Dock icon); a
running instance is killed with `pkill -f MacNowPlaying.app`.

## What this project is

A macOS now-playing companion. The reusable core is `MediaRemoteBridge` in
`NowPlaying.swift` — it reads the system's now-playing state (track, artist, live
playback position). The synced-lyrics karaoke overlay is feature #1 built on that
engine; Discord Rich Presence and a menubar readout are planned on the same core.
Do not treat this as "a lyrics app" — keep the now-playing engine independent of
the lyrics feature.

## Architecture

**Everything external is a subprocess, on purpose.** This is the load-bearing
design decision; do not "modernize" either to a native API without re-verifying.

- **Now playing** (`NowPlaying.swift`): runs a JXA script via `/usr/bin/osascript`.
  On macOS 15.4+ MediaRemote only serves now-playing data to **Apple-signed**
  callers (platform binaries / Apple's team). A compiled third-party binary is
  denied regardless of signature — verified: `MRNowPlayingRequest` returns nil and
  the async `MRMediaRemoteGetNowPlayingInfo` C function fires with an empty dict,
  under both ad-hoc and Apple-Development signing. `osascript` is a platform binary,
  so the app borrows its privilege. A native `MRNowPlayingRequest` call only works
  when the host process is Apple-signed (e.g. `swift file.swift` inside
  `swift-frontend`), which a shipped app never is.
- **Lyrics** (`Lyrics.swift`): fetches from LRCLIB via `/usr/bin/curl`. `URLSession`
  (every variant) stalls ~8s under this app's AppKit run loop; the `curl` subprocess
  returns normally.
- Both read the subprocess via `readDataToEndOfFile()` with **stderr →
  `FileHandle.nullDevice`** — an unread, full stderr pipe deadlocks the child so
  stdout never closes. `osascript` has no timeout, so its call also arms a 5s
  watchdog (`proc.terminate()`); without it a wedged query would stick `isPolling`
  true and freeze polling forever.

**Data flow** (`PlayerModel.swift`, `@MainActor` `ObservableObject`): two timers.
- `poll()` every 1s runs the MediaRemote query off-main (`Task.detached`), guarded
  by `isPolling` so a slow query never stacks overlapping subprocess spawns. On a
  new `trackKey` it serves from `lyricsCache` (empty results cached too, so
  "no-lyrics" tracks aren't refetched) or kicks off a background LRCLIB fetch.
- `tick()` every 0.08s recomputes `currentIndex` from the interpolated position.
- `currentIndex == -1` means "not started" (before the first line) — the view
  renders line 0 as a dim upcoming neighbour rather than highlighting it.
- `hasContent` (`isPlaying && (!lines.isEmpty || isFetching)`) governs whether the
  window is on screen at all — a track with no lyrics hides the window entirely so
  it stops catching hover/scroll.

**Playback position is interpolated.** MediaRemote's `ElapsedTime` is a sample taken
at `Timestamp`; it does not tick on its own (especially web players). `virtualElapsed`
projects it forward: `elapsed + (now − timestamp) × rate`. `trackKey` deliberately
**excludes duration** — web players report duration late/fluctuating, which would
churn the key and refetch endlessly.

**Sync-offset model is two-tier — preserve this, don't flatten to one offset.**
The user calibrates timing by scrolling over the overlay (`nudgeSync`). On track
change/end, `commit()` persists it: per-song exact corrections live in `trackOffsets`
(keyed by `trackKey`, applied on replay), while only **modest** corrections (≤2.5s)
ease the global `learnedOffset` baseline that unseen songs start from. A large
per-song outlier (e.g. a −5s remaster) stays with its song and must never drag songs
that already play correctly.

**Overlay geometry & click-through are split across `LyricsView.swift` and
`main.swift`, and the constants must stay in sync.** `LyricsView` pins the current
line `currentLineFromBottom` (78) up from the window bottom, one `rowHeight` (54)
tall, current line at font size 30 / `.bold` / horizontal padding 34. `AppDelegate`
mirrors these (`currentLineFromBottom`, `centerBandHeight`, `currentLineFont`,
`textHPadding`). The window is `ignoresMouseEvents` (click-through) by default; a
0.15s hover timer polls the cursor against `currentLineRect` — a band sized to the
**current line's measured text width** (via `NSFont` metrics matching the SwiftUI
font) — and only there flips the window interactive (hover brightens, scroll
calibrates). So only the visible glyphs catch the mouse; empty margins pass clicks
through. If you restyle the current line in `LyricsView`, update the `AppDelegate`
constants too.
