import Foundation

/// Decides whether a now-playing source is a *real music app* — the gate that keeps
/// Discord Rich Presence from publishing for random browser video, streams, or other
/// non-music media. A faithful port of the source-allowlist filter in the sibling
/// `telegram-audio-discord` project (`getMediaSource` + `isTelegramVoiceMessage`),
/// plus Spotify.
///
/// Why an allowlist at all: MediaRemote exposes no "is this music?" media-type field
/// (verified — `nowPlayingInfo` carries no usable kind/type for web players), so the
/// only signal we have is the source app's bundle id (and, for one legacy Chromium
/// PWA loader, its process command line). See `sourceBundle`/`sourcePID` on
/// `NowPlaying`, captured from the MediaRemote client path.
///
/// The pure logic (bundle allowlist, the Telegram voice-message regex, the YT Music
/// extension-suffix check) is kept separate from the one impure branch (the
/// `app_mode_loader` `ps` lookup) so it's unit-testable without a live process.
enum MediaSource {

    /// Which allowlisted music source a now-playing read came from. Carries the two
    /// Discord-facing bits the presence needs per source: the uploaded Art-Asset KEY
    /// for the small badge / static fallback image, and a human label for hover text.
    /// Mirrors the sibling project's per-source `smallImageKey` / `fallbackImage` /
    /// `sourceText`.
    enum Source: Equatable {
        case spotify, telegram, youTubeMusic

        /// Discord Art-Asset key — the name an image must be uploaded under in the
        /// LocalMusic app's Rich Presence → Art Assets. Used for both the small badge
        /// (`small_image`) and the static large-image fallback when no cover resolves.
        var imageKey: String {
            switch self {
            case .spotify: return "spotify"
            case .telegram: return "telegram"
            case .youTubeMusic: return "youtube-music"
            }
        }

        /// Human-readable source name (hover text / fallback large-image text).
        var label: String {
            switch self {
            case .spotify: return "Spotify"
            case .telegram: return "Telegram"
            case .youTubeMusic: return "YouTube Music"
            }
        }
    }

    // Spotify desktop app.
    private static let spotifyBundle = "com.spotify.client"

    // Telegram desktop variants (macOS App Store build, Telegram Desktop, tdesktop).
    private static let telegramBundles: Set<String> = [
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "com.tdesktop.Telegram",
    ]

    // The YouTube Music PWA Chrome extension id. Browser PWAs surface as
    // `com.google.Chrome.app.<id>` / `com.brave.Browser.app.<id>`, so we match the
    // trailing `.<id>` rather than an exact bundle.
    private static let ytMusicExtensionID = "cinhimbnkkaeohfgghhklpknlkffjgod"

    /// Which allowlisted music source this read came from, or nil when it isn't one
    /// (browser video, streams, unknown apps — or a Telegram voice/video message,
    /// whose "title" is a clock time). The only impure branch is the `app_mode_loader`
    /// `ps` lookup; everything else is pure. Branches mirror the old `isMusic` exactly.
    static func classify(bundle: String, title: String, pid: Int32) -> Source? {
        // Spotify.
        if bundle == spotifyBundle { return .spotify }

        // Telegram — but reject voice/video messages (their "title" is a timestamp).
        if telegramBundles.contains(bundle) {
            return isTelegramVoiceMessage(title) ? nil : .telegram
        }

        // YouTube Music as a browser PWA: extension-suffix bundle (pure).
        if bundle.hasSuffix(".\(ytMusicExtensionID)") { return .youTubeMusic }

        // Older Chromium PWA loader: bundle is the generic `app_mode_loader`, so the
        // only way to tell YT Music from any other PWA is the process command line.
        // Impure + cached; the cache makes this at most one `ps` per 30s per pid.
        if bundle == "app_mode_loader", pid > 0 {
            return isYouTubeMusicProcess(pid: pid) ? .youTubeMusic : nil
        }

        // Everything else (Safari/Chrome/Brave/Firefox video, streams, unknown apps).
        return nil
    }

    /// True iff the source is an allowlisted music app and (for Telegram) the track
    /// isn't a voice/video message. Thin wrapper over `classify`.
    static func isMusic(bundle: String, title: String, pid: Int32) -> Bool {
        return classify(bundle: bundle, title: title, pid: pid) != nil
    }

    /// Detect a Telegram voice/video message masquerading as a now-playing track.
    /// Such "titles" are short date/time references that end in a clock time, e.g.
    /// "today at 8:12 PM", "aujourd'hui à 20:12", "hier à 15:30". Pure — port of the
    /// sibling project's `isTelegramVoiceMessage`.
    static func isTelegramVoiceMessage(_ title: String) -> Bool {
        guard title.count <= 40 else { return false }
        // \d{1,2}:\d{2}(\s*(AM|PM))?$  — case-insensitive, anchored to the end.
        let pattern = #"\d{1,2}:\d{2}(\s*(AM|PM))?$"#
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    // MARK: - Impure: app_mode_loader ps lookup (cached)

    private struct CacheEntry { let isYtMusic: Bool; let at: Date }
    private static let cacheTTL: TimeInterval = 30
    // Guards the per-pid cache. `isMusic` is called from `PlayerModel.updatePresence`
    // on the main thread, but the `ps` branch only fires for the rare `app_mode_loader`
    // bundle and at most once per 30s per pid, so a brief synchronous `ps` there is
    // acceptable (see PlayerModel / CLAUDE.md). The lock keeps the cache itself safe.
    private static let cacheLock = NSLock()
    private static var pidCache: [Int32: CacheEntry] = [:]

    /// Run `ps -p <pid> -o args=` and check whether the command line names the YouTube
    /// Music PWA. Cached per-pid for `cacheTTL` so we don't spawn `ps` every poll.
    private static func isYouTubeMusicProcess(pid: Int32) -> Bool {
        let now = Date()
        cacheLock.lock()
        if let cached = pidCache[pid], now.timeIntervalSince(cached.at) < cacheTTL {
            cacheLock.unlock()
            return cached.isYtMusic
        }
        cacheLock.unlock()

        let isYtMusic = processArgs(pid: pid)?
            .lowercased()
            .contains("youtube music.app") ?? false

        cacheLock.lock()
        pidCache[pid] = CacheEntry(isYtMusic: isYtMusic, at: now)
        cacheLock.unlock()
        return isYtMusic
    }

    /// `ps -p <pid> -o args=` → the process's command line, or nil on failure.
    /// Same subprocess style as the rest of the project: stdout pipe, stderr →
    /// nullDevice (an unread full stderr pipe would deadlock the child), read to end.
    private static func processArgs(pid: Int32) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "args="]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }

        // Bound the subprocess with a watchdog (mirrors NowPlaying.query): classify
        // can run on the main thread (PlayerModel.updatePresence is @MainActor), so a
        // wedged `ps` must never block forever. Terminating closes the pipe, so the
        // read below unblocks and we fall through.
        let watchdog = DispatchWorkItem { proc.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }
}
