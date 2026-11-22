import Foundation
import CryptoKit

/// On-disk persistence for resolved lyrics, layered behind `PlayerModel`'s
/// in-memory `lyricsCache`. We mostly replay our own library, and LRCLIB is
/// often slow (and 504s under concurrent load), so a track resolved once should
/// load instantly — and offline — on every later play, across app restarts.
///
/// One JSON file per track under Caches, named by a SHA-256 of the `trackKey`
/// (which is free-form `"artist|title"` and can't be a filename directly). This
/// is a generic key→`[LyricLine]` store; the *policy* of what's worth persisting
/// lives in the caller (`PlayerModel`), which writes only tracks it actually
/// found lyrics for — real lyrics never go stale, whereas an empty result can
/// (a new release gets lyrics added later), so empties stay in memory only and
/// transient failures (504/non-JSON/network) are never written at all.
///
/// Caches (not Application Support) is deliberate: this is re-derivable data, so
/// it's fine for the OS to purge it under disk pressure — we just refetch.
enum LyricsCache {
    /// Storage directory override for tests. nil → the default Caches location.
    static var overrideDirectory: URL?

    /// The default Caches location, resolved and created exactly once per process
    /// (lazy `static let` is thread-safe). nil only if the Caches directory itself
    /// can't be located, in which case caching no-ops silently.
    private static let defaultDirectory: URL? = {
        guard let base = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let dir = base.appendingPathComponent("MacNowPlaying/lyrics", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// Resolve (and ensure) the cache directory. The default path is created once
    /// (above); a test `overrideDirectory` is created on demand since it changes
    /// per test. Returns nil only when no Caches directory exists.
    private static func directory() -> URL? {
        guard let dir = overrideDirectory else { return defaultDirectory }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func fileURL(for trackKey: String) -> URL? {
        guard let dir = directory() else { return nil }
        let digest = SHA256.hash(data: Data(trackKey.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return dir.appendingPathComponent(name).appendingPathExtension("json")
    }

    /// The cached lyrics for a track, or nil if no result was ever stored for it.
    /// A stored empty array is a real cached answer ("no synced lyrics") and
    /// returns `[]`; only a missing/unreadable file returns nil. Reading a small
    /// JSON file is cheap enough to call on the main thread on a track change.
    static func load(_ trackKey: String) -> [LyricLine]? {
        guard let url = fileURL(for: trackKey),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode([LyricLine].self, from: data)
    }

    /// Persist a definitive result (lyrics, or a genuine empty). Best-effort and
    /// atomic: a write failure just means the next session refetches.
    static func save(_ lines: [LyricLine], for trackKey: String) {
        guard let url = fileURL(for: trackKey),
              let data = try? JSONEncoder().encode(lines) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
