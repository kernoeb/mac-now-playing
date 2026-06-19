import SwiftUI
import Combine

/// Ties together: polling MediaRemote → fetching lyrics → tracking the current line.
@MainActor
final class PlayerModel: ObservableObject {
    @Published var lines: [LyricLine] = []
    @Published var currentIndex: Int = -1
    @Published var isHovering = false
    @Published private(set) var isPlaying = false    // overlay hides when false (paused/stopped/finished)
    @Published private(set) var isFetching = false   // a lyrics fetch is in flight

    /// User-facing switch from the menubar: when false the overlay window stays off
    /// screen even while music plays (the hover timer in AppDelegate gates on this
    /// together with `hasContent`).
    @Published var overlayEnabled = true

    /// User-facing switch from the menubar: when false we stop publishing Discord
    /// Rich Presence and clear any existing one. Default ON. (Independent of the
    /// overlay — Discord is a parallel consumer of the now-playing engine.)
    @Published var discordEnabled = true {
        didSet {
            guard discordEnabled != oldValue else { return }
            if discordEnabled {
                lastPresenceKey = nil   // force the next apply to (re)publish
                if isPlaying { updatePresence() }
            } else {
                discord?.clear()
                lastPresenceKey = nil
            }
        }
    }

    /// The Discord Rich Presence client, injected by AppDelegate. Optional so the
    /// now-playing engine stands alone (debug entry points, tests) without it.
    var discord: DiscordRPC?

    // Change-detection for presence: a signature of the last activity we sent. We
    // only push a new SET_ACTIVITY when this changes (track, play/pause, or a seek),
    // never on every 1s poll — the start/end timestamps make Discord animate the
    // progress bar on its own, and this stays well under Discord's ~15s rate limit.
    private var lastPresenceKey: String?

    /// Current "Artist · Title" for the menubar readout, or nil when idle. Uses a
    /// middle dot (no em dash) per the app's text style.
    @Published private(set) var currentTrack: String?

    /// Menubar status-row text: the current track, or a "Nothing playing" idle state.
    var nowPlayingDescription: String {
        guard isPlaying, let currentTrack else { return "Nothing playing" }
        return currentTrack
    }

    /// Whether the overlay window should be on screen at all: only when music is
    /// playing AND we either have lyrics or are still looking them up. No music,
    /// or a track with no synced lyrics → the window is hidden entirely (not just
    /// transparent) so it stops reacting to hover/scroll over empty space.
    var hasContent: Bool { isPlaying && (!lines.isEmpty || isFetching) }

    /// Live sync correction applied to the current track (seconds). + = lyrics
    /// earlier, − = later. Starts each track from `learnedOffset`; the user
    /// refines it by scrolling over the overlay.
    @Published var syncOffset: Double = UserDefaults.standard.double(forKey: PlayerModel.offsetKey)

    /// Per-song corrections, keyed by trackKey. The per-song latency is largely
    /// random (a remaster, an MV edit, a different upload), so a correction must
    /// stick to ITS song and nowhere else — otherwise fixing one outlier drags
    /// every other song off. A song replays with exactly the offset you last gave it.
    private var trackOffsets: [String: Double] =
        UserDefaults.standard.dictionary(forKey: PlayerModel.trackOffsetsKey) as? [String: Double] ?? [:]
    private static let trackOffsetsKey = "syncTrackOffsets"

    /// Gentle global baseline that UNSEEN songs start from — the typical output
    /// latency. Only MODEST corrections feed it (see `commit`); large per-song
    /// outliers are remembered per-song above and never allowed to poison it.
    private var learnedOffset: Double = UserDefaults.standard.double(forKey: PlayerModel.offsetKey)
    private static let offsetKey = "syncLearnedOffset"

    // Interpolation state, refreshed on every poll.
    private var baseElapsed: Double = 0
    private var baseDate = Date()
    private var sampleTimestamp: Double = 0
    private var rate: Double = 1

    private var currentTrackKey: String?

    // The most recent valid snapshot, so the menubar toggle can re-publish presence
    // without waiting for the next poll.
    private var lastNowPlaying: NowPlaying?

    // The track-position start epoch we last sent to Discord, for seek detection.
    private var lastPresenceStart: Double = 0

    // What syncOffset was set to when the current track loaded. Lets `commit`
    // tell a deliberate adjustment from an untouched track, so only songs you
    // actually corrected ever take a slot in `trackOffsets`.
    private var loadedOffset: Double = 0

    // Synced lyrics already fetched this session, keyed by trackKey. Avoids
    // re-hitting LRCLIB when the user replays or skips back to a track. A genuine
    // "LRCLIB has no synced lyrics for this track" empty IS cached (so lyric-less
    // tracks aren't refetched forever); a transient fetch failure (504/non-JSON/
    // network) is NOT cached, so the next 1s poll retries and self-heals.
    private var lyricsCache: [String: [LyricLine]] = [:]

    // Resolved cover URLs, keyed by trackKey. Negative results (no iTunes match) are
    // cached too — as `.some(nil)` — so we hit the Search API at most once per track
    // and a no-art track doesn't get retried on every poll. A track in flight is
    // tracked by `artworkResolving` so concurrent polls don't spawn duplicate lookups.
    private var artworkCache: [String: String?] = [:]
    private var artworkResolving: Set<String> = []

    // True while a MediaRemote query is in flight, so the 1s poll never stacks
    // overlapping subprocess spawns if a query outruns the interval.
    private var isPolling = false

    private var pollTimer: Timer?
    private var tickTimer: Timer?

    func start() {
        // Poll MediaRemote once a second (cheap; runs the JXA query off-main).
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }   // Timer fires on the main run loop
        }
        // Advance the highlighted line smoothly between polls.
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        poll()
    }

    /// Live playback position. `elapsed` is sampled at `sampleTimestamp` (the
    /// player's clock) and doesn't tick on its own — especially for web players —
    /// so we project forward from that timestamp. Falls back to our own poll time
    /// if the player didn't supply a timestamp.
    private var virtualElapsed: Double {
        guard isPlaying else { return baseElapsed }
        let reference = sampleTimestamp > 0 ? sampleTimestamp : baseDate.timeIntervalSince1970
        return baseElapsed + (Date().timeIntervalSince1970 - reference) * rate
    }

    private func poll() {
        guard !isPolling else { return }   // previous query hasn't returned yet
        isPolling = true
        Task.detached(priority: .utility) {
            let np = MediaRemoteBridge.query()
            await MainActor.run {
                self.isPolling = false
                self.apply(np)
            }
        }
    }

    private func apply(_ np: NowPlaying?) {
        guard let np, np.isValid else {
            isPlaying = false
            isFetching = false
            currentTrack = nil
            clearPresence()                    // nothing playing → clear Discord
            if let leaving = currentTrackKey {
                commit(for: leaving)           // remember the track that just ended
                currentTrackKey = nil
                lines = []
                currentIndex = -1
            }
            return
        }

        // Re-sync interpolation baseline.
        baseElapsed = np.elapsed
        baseDate = Date()
        sampleTimestamp = np.timestamp
        isPlaying = np.isPlaying && np.rate > 0
        rate = np.rate > 0 ? np.rate : 1

        // Drive Discord presence from the same snapshot (parallel to lyrics, runs
        // every poll but only actually sends when something meaningful changed).
        updatePresence(for: np)

        // New track? Serve from cache, otherwise fetch its lyrics.
        if np.trackKey != currentTrackKey {
            if let leaving = currentTrackKey { commit(for: leaving) }  // remember the track we're leaving
            // Menubar readout (middle dot separator, no em dash). Track identity is
            // (artist, title) — the same inputs as trackKey — so it only changes here.
            currentTrack = np.artist.isEmpty ? np.title : "\(np.artist) · \(np.title)"
            // Known song → its own saved offset; unseen song → the gentle baseline.
            syncOffset = trackOffsets[np.trackKey] ?? learnedOffset
            loadedOffset = syncOffset
            currentTrackKey = np.trackKey
            currentIndex = -1

            if let cached = lyricsCache[np.trackKey] {
                lines = cached
                isFetching = false
                return
            }

            lines = []
            isFetching = true
            // Fetch on a plain GCD background queue. The Swift-concurrency +
            // URLSession bridge stalls under AppKit's run loop, so we avoid it.
            DispatchQueue.global(qos: .userInitiated).async {
                let fetched = LRCLIB.fetchSynced(for: np)
                DispatchQueue.main.async {
                    guard np.trackKey == self.currentTrackKey else { return }
                    guard let fetched else {
                        // Transient failure (504/non-JSON/network). Don't cache, and
                        // clear currentTrackKey so the next 1s poll re-enters this
                        // branch and retries — self-healing instead of stuck on the
                        // loading dots forever. isFetching stays true so hasContent
                        // keeps the overlay alive across the retry.
                        self.currentTrackKey = nil
                        return
                    }
                    // Definitive result (lyrics, or a genuine empty). Cache it (valid
                    // for np.trackKey) so we don't refetch, and show it live.
                    self.lyricsCache[np.trackKey] = fetched
                    self.lines = fetched
                    self.isFetching = false
                }
            }
        }
    }

    /// Switch to a line slightly BEFORE its timestamp so it finishes gliding to
    /// the centre right as it's sung — compensates for the spring's settle time
    /// (and a little for loose LRC files / audio latency). Bump if still late.
    private let leadTime: Double = 0.2

    /// Apply a live user correction from the scroll wheel. Responsive (takes
    /// effect immediately); the value is folded into `learnedOffset` when the
    /// track ends so it persists and converges.
    func nudgeSync(by delta: Double) {
        syncOffset = (min(15, max(-15, syncOffset + delta)) * 100).rounded() / 100
    }

    /// Persist a just-finished track's correction. The offset is saved per-song
    /// (so it's exact next replay), and ONLY modest corrections ease the global
    /// baseline — a large outlier like −5s stays with its song and can't drag the
    /// songs that already play correctly.
    private func commit(for trackKey: String) {
        // Untouched track → leave the store alone (don't add a slot for every song
        // that merely played through).
        guard abs(syncOffset - loadedOffset) >= 0.05 else { return }

        if abs(syncOffset) < 0.05 {
            trackOffsets.removeValue(forKey: trackKey)            // correction cleared → reclaim the slot
        } else {
            trackOffsets[trackKey] = syncOffset
        }
        UserDefaults.standard.set(trackOffsets, forKey: PlayerModel.trackOffsetsKey)

        guard abs(syncOffset) <= 2.5 else { return }              // outlier → per-song only
        if learnedOffset == 0 {
            learnedOffset = syncOffset                            // first calibration → adopt
        } else if syncOffset != learnedOffset {
            learnedOffset += 0.4 * (syncOffset - learnedOffset)   // ease toward the new value
        }
        UserDefaults.standard.set(learnedOffset, forKey: PlayerModel.offsetKey)
    }

    // MARK: - Discord Rich Presence

    /// Re-publish presence from the last known snapshot (used by the menubar toggle).
    private func updatePresence() {
        if let np = lastNowPlaying { updatePresence(for: np) }
    }

    /// Push the current track to Discord — but only when something meaningful changed
    /// (track, play↔pause, or a seek of more than a few seconds vs. the projected
    /// position). Never sends on a steady 1s poll: Discord animates the progress bar
    /// itself from the start/end timestamps, so a playing track that hasn't been
    /// seeked needs no further updates.
    private func updatePresence(for np: NowPlaying) {
        lastNowPlaying = np
        guard discordEnabled, let discord else { return }

        guard isPlaying else { clearPresence(); return }

        // Only publish for real music apps (Spotify / Telegram / YouTube Music) — a
        // non-music source (browser video, stream, unknown app) clears any existing
        // presence and sends nothing. Scope is Discord only; the lyrics overlay is
        // unaffected. The `source` also drives the per-source badge + static fallback
        // art below. See MediaSource.swift.
        guard let source = MediaSource.classify(bundle: np.sourceBundle, title: np.title, pid: np.sourcePID) else {
            clearPresence(); return
        }

        // timestamps.start = wall-clock when the track was at position 0, derived from
        // the same interpolation basis the model uses (elapsed sampled at timestamp).
        // Discord then renders the live bar from start (and end, if we know duration).
        let reference = np.timestamp > 0 ? np.timestamp : Date().timeIntervalSince1970
        let startEpoch = reference - np.elapsed
        let start = Date(timeIntervalSince1970: startEpoch)
        // Omit `end` when duration is unknown/invalid (web players report it late) —
        // Discord then shows elapsed-only instead of a wrong full bar.
        let end = np.duration > 0 ? Date(timeIntervalSince1970: startEpoch + np.duration) : nil

        // Resolve album art (once per track, cached). When it lands we re-enter this
        // method for the same track with the URL now in the cache — folding `hasArt`
        // into the change key lets exactly that one art-driven re-send through the
        // dedupe below, instead of being suppressed as "nothing changed".
        let art = artworkURL(for: np)

        // Change signature: track identity + whether we have an end + whether we have
        // art. The derived start epoch is compared with a tolerance (not folded into
        // the key) so small jitter — or a web player that doesn't update its timestamp,
        // making us fall back to wall-clock — doesn't churn presence every poll. A real
        // seek shifts the start by more than the tolerance and forces a re-send so
        // Discord's bar resnaps to the new position. The large image is now ALWAYS set
        // (real cover or source-key fallback), but `art != nil` still flips once the
        // background lookup lands, so the one art-driven re-send still passes the dedupe
        // and the real cover replaces the fallback key.
        let key = "\(np.trackKey)|\(np.duration > 0)|\(art != nil)"
        // Only trust seek detection with a real player timestamp: web players report
        // their timestamp late, so their startEpoch (derived from wall-clock) drifts
        // and would falsely register a seek on every poll, churning presence.
        let seeked = np.timestamp > 0 && abs(startEpoch - lastPresenceStart) > 3
        if key == lastPresenceKey && !seeked { return }
        lastPresenceKey = key
        lastPresenceStart = startEpoch

        // `name` is what Discord shows after "Listening to" — set it to the track so
        // the song is the headline, not the app name "LocalMusic". (details/state
        // render as the lines beneath.) Matches telegram-audio-discord's displayName.
        let name = np.artist.isEmpty ? np.title : "\(np.title) - \(np.artist)"

        // Large image: the resolved cover URL, OR the source's static asset key as a
        // fallback when no cover resolved (mirrors `artworkUrl || fallbackImage`). So
        // the large image is always present — a real cover, or the source badge as a
        // stand-in (which renders once that key is uploaded to the Discord portal).
        // Small image: always the source badge key. Both render only after the keys
        // `spotify`/`telegram`/`youtube-music` are uploaded; until then Discord just
        // shows no icon (graceful), while real cover URLs work with no upload.
        let largeImage = art ?? source.imageKey
        let largeImageText = np.album.isEmpty
            ? (np.title.isEmpty ? source.label : np.title)
            : np.album

        discord.setActivity(.init(
            name: name,
            details: np.title,
            state: np.artist,
            start: start,
            end: end,
            largeImage: largeImage,
            largeImageText: largeImageText,
            smallImage: source.imageKey,
            smallImageText: source.label
        ))
    }

    /// The cover URL for a track if we have one cached, kicking off a one-time
    /// background lookup when we don't. Returns nil while the lookup is in flight (and
    /// for tracks iTunes can't match — that negative is cached). Only the network call
    /// runs off-main; the cache read/write and the re-send stay on the main actor.
    private func artworkURL(for np: NowPlaying) -> String? {
        let trackKey = np.trackKey
        if let cached = artworkCache[trackKey] { return cached }   // .some(nil) = no art
        guard !artworkResolving.contains(trackKey) else { return nil }
        artworkResolving.insert(trackKey)

        let title = np.title, artist = np.artist, album = np.album
        DispatchQueue.global(qos: .utility).async {
            let url = Artwork.coverURL(title: title, artist: artist, album: album)
            DispatchQueue.main.async {
                self.artworkResolving.remove(trackKey)
                self.artworkCache[trackKey] = url   // cache the result (nil included)
                // Only re-send if the track this art belongs to is still the one
                // actually playing AND we found art. Gate on the LIVE now-playing
                // identity (lastNowPlaying), not currentTrackKey: during a lyrics 504
                // retry currentTrackKey is transiently nil, and a cover landing in that
                // window would otherwise be dropped forever (cache is populated, no
                // re-lookup). lastNowPlaying still reflects the playing track.
                guard url != nil,
                      let np = self.lastNowPlaying, np.trackKey == trackKey else { return }
                self.updatePresence(for: np)
            }
        }
        return nil
    }

    /// Clear Discord presence (paused / stopped / nothing playing). Idempotent.
    private func clearPresence() {
        guard lastPresenceKey != nil else { return }
        lastPresenceKey = nil
        lastPresenceStart = 0
        discord?.clear()
    }

    private func tick() {
        guard !lines.isEmpty else { return }
        let t = virtualElapsed + leadTime + syncOffset
        // Last line whose timestamp is at or before the current position.
        // Before the first line is reached we stay at -1 ("not started"): the
        // view then renders line 0 as the dimmed upcoming neighbour instead of
        // highlighting it at centre.
        var idx = -1
        // lines are sorted by time, so stop at the first one still in the future.
        for (i, line) in lines.enumerated() {
            if line.time <= t { idx = i } else { break }
        }
        // Let the view's .animation(value: currentIndex) drive the motion.
        if idx != currentIndex { currentIndex = idx }
    }
}
