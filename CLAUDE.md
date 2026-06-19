# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```sh
swift build                 # debug build
swift build -c release      # optimised build
swift run                   # build + launch the overlay (no Dock icon; Ctrl-C to quit)
swift test                  # run the test suite (XCTest)
swift test --filter testParsesBasicTimestamps   # run a single test by method name

./scripts/build-app.sh      # → MacNowPlaying.app (release, ad-hoc signed)
./scripts/install.sh        # build + copy to /Applications

# Debug entry points (compiled into the app, see main.swift):
.build/debug/MacNowPlaying --now                          # print the current now-playing read, exit
.build/debug/MacNowPlaying --probe "Artist" "Title" 200   # fetch + print lyrics for a track, exit
.build/debug/MacNowPlaying --discord                      # send a test Discord presence ~3s, clear, exit
```

There is no linter configured. The app is a `LSUIElement` agent (no Dock icon); a
running instance is killed with `pkill -f MacNowPlaying.app`.

Target resources (e.g. the menubar `tray-icon.png`) are loaded via `Bundle.module`.
SwiftPM emits them into a `MacNowPlaying_MacNowPlaying.bundle` next to the binary, so
`scripts/build-app.sh` must copy that bundle into the `.app`'s `Contents/Resources` — without
it `Bundle.module` fatal-errors at launch. `swift run` finds it automatically.

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
- **Artwork** (`Artwork.swift`): resolves Discord cover art via `/usr/bin/curl` — same
  curl-not-URLSession rule as `Lyrics.swift`. Discord's `large_image` can't take local
  artwork bytes; it needs a pre-uploaded asset key or an external `https` URL, so we
  look one up per track and pass it as the activity's large image. `coverURL` is an
  **ordered resolver** that returns the first hit: **iTunes Search API first
  (`iTunesCoverURL`, mirrors `curlJSON`), then a YouTube-thumbnail lookup
  (`youTubeThumbnailURL` → `curlText` of the results page, then the pure
  `firstYouTubeVideoID` regex → `i.ytimg.com/.../maxresdefault.jpg`)**. The order is
  deliberately a single, obvious, easily-swapped sequence in `coverURL` (the user wants
  iTunes-first parity for now but may flip it later) — reorder by rearranging the two
  calls. `PlayerModel` caches the result per `trackKey` (negatives cached too) so we
  hit the chain at most once per track.
- Both read the subprocess via `readDataToEndOfFile()` with **stderr →
  `FileHandle.nullDevice`** — an unread, full stderr pipe deadlocks the child so
  stdout never closes. `osascript` has no timeout, so its call also arms a 5s
  watchdog (`proc.terminate()`); without it a wedged query would stick `isPolling`
  true and freeze polling forever.

**Data flow** (`PlayerModel.swift`, `@MainActor` `ObservableObject`): two timers.
- `poll()` every 1s runs the MediaRemote query off-main (`Task.detached`), guarded
  by `isPolling` so a slow query never stacks overlapping subprocess spawns. On a
  new `trackKey` it serves from `lyricsCache` (a genuine "LRCLIB has no synced
  lyrics" empty IS cached, so "no-lyrics" tracks aren't refetched; a transient
  fetch failure — 504/non-JSON/network, surfaced as `fetchSynced` returning `nil`
  — is NOT cached, so the next poll retries and self-heals) or kicks off a
  background LRCLIB fetch.
- `tick()` every 0.08s recomputes `currentIndex` from the interpolated position.
- `currentIndex == -1` means "not started" (before the first line) — the view
  renders line 0 as a dim upcoming neighbour rather than highlighting it.
- `hasContent` (`isPlaying && (!lines.isEmpty || isFetching)`) governs whether the
  window is on screen at all — a track with no lyrics hides the window entirely so
  it stops catching hover/scroll. The hover timer in `AppDelegate` actually shows
  the window only when `hasContent && model.overlayEnabled`; `overlayEnabled` is the
  user-facing "Show Overlay" toggle in the menubar (`MenuBar.swift`), so turning it
  off orders the window out (and resets hover / `ignoresMouseEvents`) even while
  music plays.

**Discord Rich Presence** (`DiscordRPC.swift`, feature #2): a dependency-free client
for Discord's local IPC — raw POSIX `AF_UNIX` socket to `$TMPDIR/discord-ipc-N`,
framed `[UInt32 LE opcode][UInt32 LE length][JSON]`, handshake → await `READY`, then
`SET_ACTIVITY` (type 2 = Listening → "Listening to LocalMusic"). All socket I/O is on
a private serial queue; if Discord isn't running every call is a quiet no-op (no
crash, no hang). The client ID `834057528828100668` is hardcoded — a client ID is
**public**, not a secret (the Developer-Portal app *name* is what renders after
"Listening to"). It's driven from `PlayerModel.apply` — the one place with the full
`NowPlaying` — gated by `discordEnabled` (menubar toggle, default ON) and
**throttled on change**: presence is only sent on a track change, play↔pause, or a
seek (>3s vs. the projected start), never on the steady 1s poll. Discord animates the
progress bar itself from `timestamps.start/end`, so no per-second updates are needed
(this also stays under Discord's ~15s rate limit). Keep this independent of the
lyrics feature — it's a parallel consumer of the now-playing engine. **Timestamp-unit
gotcha**: local IPC `SET_ACTIVITY` takes Unix epoch **seconds** (what we ship); the
Gateway/REST API uses milliseconds. If the bar ever renders wrong, flip the unit in
`sendActivityLocked` (one spot, noted in a comment). **Assets (badge + art)**: the
activity carries four asset fields — `large_image` (a cover URL **or** an asset key),
`large_text`, `small_image` (always an asset key — the per-source badge),
`small_text`. `ActivityPayload.Assets` builds the `assets` object when ANY field is
set (so a no-cover track still ships its source badge) and omits it only when all are
nil. The large image is **always set**: `art ?? source.imageKey` — the resolved cover
URL if we have one, otherwise the source's static asset key as a fallback (mirrors the
sibling project's `artworkUrl || fallbackImage`). The text presence + badge + fallback
go out immediately; the real cover is resolved on a background queue and, when it lands
AND it's still the current track, `updatePresence(for:)` re-fires. The change key folds
in `art != nil` (alongside trackKey + has-end) so this one art-driven re-send isn't
suppressed by the dedupe and the real cover replaces the fallback key. The art lookup
is gated behind the same `discordEnabled`/`isPlaying`/`MediaSource.classify` guards.
**Uploaded asset keys (one-time Discord Portal setup)**: the small badge and the static
large-image fallback render only if images are uploaded to the LocalMusic app (Rich
Presence → Art Assets) under the exact keys `spotify`, `telegram`, `youtube-music`.
Until then Discord shows no badge / no fallback image (graceful); the real
iTunes/YouTube cover URLs need no upload.

**Source-allowlist gate** (`MediaSource.swift`): presence is published only for real
music apps. `updatePresence(for:)` calls `MediaSource.classify(bundle:title:pid:)`
after the `discordEnabled`/`isPlaying` guards; it returns a `Source`
(`.spotify`/`.telegram`/`.youTubeMusic`) or nil — a non-music source (nil) clears any
existing presence and sends nothing. The returned `Source` also drives the Discord
assets: `.imageKey` is the uploaded Art-Asset key (`spotify`/`telegram`/`youtube-music`,
used for both the small badge and the static large-image fallback) and `.label` is the
human name for hover/fallback text. `isMusic(bundle:title:pid:)` is a thin
`classify(...) != nil` wrapper kept for callers/tests that only need the boolean. This
is a faithful port of the sibling
`telegram-audio-discord` project's filter (plus Spotify). Why an allowlist and not a
media-type check: **MediaRemote exposes no "is this music?" field** — `nowPlayingInfo`
carries no usable kind/type for web players (verified), so the only signal is the
source app's bundle id, surfaced as `NowPlaying.sourceBundle` (and `sourcePID`), both
captured from the MediaRemote **client path** (`localNowPlayingPlayerPath.client`:
`parentApplicationBundleIdentifier` → `bundleIdentifier` for the bundle,
`processIdentifier` for the pid) in the JXA bridge. Allowlisted: Spotify
(`com.spotify.client`); Telegram (three bundle ids — but a voice/video message, whose
"title" is a clock time like "today at 8:12 PM" / "aujourd'hui à 20:12", is rejected
via `isTelegramVoiceMessage`); YouTube Music as a browser PWA (bundle ending in the
extension id `.cinhimbnkkaeohfgghhklpknlkffjgod`, OR the older Chromium
`app_mode_loader` bundle whose process command line — read via `ps -p <pid> -o args=`
— names "youtube music.app"). The pure logic (bundle/regex/suffix) is separated from
the impure `ps` branch so it's unit-testable (`MediaSourceTests`). The `app_mode_loader`
`ps` call is the only impure branch: it fires only for that rare bundle and its results
are cached per-pid for 30s, so it runs at most once per 30s per pid — cheap enough to
stay on the main-thread `updatePresence` path without a detached task.

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
