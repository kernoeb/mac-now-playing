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
