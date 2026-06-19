import Foundation

/// One timestamped lyric line.
struct LyricLine: Equatable {
    let time: Double   // seconds
    let text: String   // may be empty (instrumental break → shown as ♪)
}

/// Fetches synced lyrics from LRCLIB (free, no API key) and parses the LRC format.
enum LRCLIB {
    // LRCLIB politely asks clients to identify themselves. Shared with Artwork's
    // iTunes lookup so both HTTP clients send one consistent User-Agent.
    static let userAgent = "mac-now-playing/0.1 (https://github.com/kernoeb/mac-now-playing)"

    /// Prefer a romanised version over the canonical Hangul one when a well-timed
    /// one is available (user preference). Set false to always use the canonical.
    static let preferRomanized = true
    /// How far a candidate's first line may differ from the canonical's before we
    /// consider it a different (mis-synced/shifted) upload and refuse to use it.
    private static let timingTolerance: Double = 4.0

    private struct Candidate {
        let lines: [LyricLine]
        var firstTime: Double { lines.first?.time ?? .infinity }
        var isRomanized: Bool { !containsHangul(lines) }
    }

    /// Resolve synced lyrics for a track. `/api/get` returns LRCLIB's single
    /// canonical match (correct timing); we fetch that AND the search candidates
    /// concurrently. The canonical defines the trusted start time. If the user
    /// prefers romanised lyrics, we swap in a romanised candidate ONLY when its
    /// first line agrees with the canonical's (so a shifted upload can never sneak
    /// in). Synchronous (shells out to `curl`) — call from a background queue.
    /// Returns the resolved synced lyrics, or `nil` when the lookup failed
    /// transiently (a 504/non-JSON/network error somewhere in the attempt chain
    /// while no lyrics were found) — `nil` must NOT be cached, so the next poll
    /// retries. A non-nil result (possibly `[]`) is definitive: LRCLIB was reached
    /// and either has no synced lyrics for this track or returned the ones below.
    static func fetchSynced(for track: NowPlaying) -> [LyricLine]? {
        let fullArtist = normalizedArtist(track.artist)
        let first = attempt(track, artist: fullArtist)
        if let lines = first.lines { return lines }
        // Collaboration credits ("Sunburn et Nelt.", "X feat. Y") usually aren't how
        // LRCLIB indexes the track — it files it under the lead act ("Sunburn"). Retry
        // with just the lead artist. This runs ONLY after the full credit misses, so a
        // band whose real name contains "and"/"&"/"," ("Florence and the Machine") is
        // matched in full first and never reaches the aggressive split.
        let lead = primaryArtist(fullArtist)
        var failed = first.failed
        if lead != fullArtist {
            let second = attempt(track, artist: lead)
            if let lines = second.lines { return lines }
            failed = failed || second.failed
        }
        // No lyrics found. If any underlying request hard-failed transiently, the
        // overall outcome is a failure (nil → don't cache, retry); otherwise every
        // request answered and this is a definitive empty ([] → cache it).
        return failed ? nil : []
    }

    /// One artist spelling, both title spellings. MediaRemote often appends a Korean
    /// subtitle ("하늘 위로 Up") while LRCLIB stores only the English part ("Up"), so on
    /// a miss we retry with the title's Hangul/parentheses stripped. Returns the
    /// found lines (nil = none found) plus whether any request failed transiently.
    private static func attempt(_ track: NowPlaying, artist: String) -> (lines: [LyricLine]?, failed: Bool) {
        let first = resolve(track, artist: artist, title: track.title)
        if let lines = first.lines, !lines.isEmpty { return (lines, false) }
        let simple = simplifiedTitle(track.title)
        if !simple.isEmpty, simple != track.title {
            let second = resolve(track, artist: artist, title: simple)
            if let lines = second.lines, !lines.isEmpty { return (lines, false) }
            return (nil, first.failed || second.failed)
        }
        return (nil, first.failed)
    }

    /// Resolve for a specific artist + title spelling. Fetches the canonical (`/api/get`)
    /// and search candidates concurrently; the canonical defines the trusted start
    /// time, and a romanised candidate is only swapped in when its timing agrees.
    /// Returns the lines (nil = no usable match) plus whether either concurrent
    /// request hard-failed transiently (so the caller can retry rather than cache).
    private static func resolve(_ track: NowPlaying, artist norm: String, title: String) -> (lines: [LyricLine]?, failed: Bool) {
        var canonical: (lines: [LyricLine]?, failed: Bool) = (nil, false)
        var search: (candidates: [Candidate], failed: Bool) = ([], false)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            canonical = getExact(track, artist: norm, title: title)
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            search = searchCandidates(track, artist: norm, title: title)
            group.leave()
        }
        group.wait()

        let candidates = search.candidates
        // A request that 504'd anywhere here means a no-match could be a false
        // negative, so propagate the failure flag whenever we end up empty-handed.
        let failed = canonical.failed || search.failed

        if let canon = canonical.lines, !canon.isEmpty {
            // Already romanised (or user doesn't care) → use the trusted version.
            guard preferRomanized, containsHangul(canon), let ref = canon.first?.time
            else { return (canon, false) }
            // Hangul canonical: prefer a romanised candidate whose timing matches.
            if let romanized = candidates.first(where: {
                $0.isRomanized && abs($0.firstTime - ref) <= timingTolerance
            }) {
                return (romanized.lines, false)
            }
            return (canon, false)
        }

        // No canonical → best-ranked search candidate, if any survived the filters.
        if let lines = candidates.first?.lines { return (lines, false) }
        return (nil, failed)
    }

    /// Strips a trailing parenthetical (e.g. the Korean name) so the artist
    /// matches LRCLIB's canonical entry: "EVERGLOW (에버글로우)" → "EVERGLOW".
    static func normalizedArtist(_ artist: String) -> String {
        let stripped = artist.replacingOccurrences(
            of: #"\s*\([^)]*\)\s*$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? artist : stripped
    }

    /// The lead act, for a fallback lookup when the full collaboration credit matches
    /// nothing: keeps the part before the first collaboration separator
    /// ("Sunburn et Nelt." → "Sunburn", "A feat. B" → "A"). Only safe because the
    /// caller tries the full credit FIRST — so a real name containing one of these
    /// tokens is matched intact before we ever cut here.
    static func primaryArtist(_ artist: String) -> String {
        // Surrounding spaces (or a leading comma) keep these from matching mid-word.
        let separators = [", ", " et ", " feat. ", " feat ", " ft. ", " ft ",
                          " featuring ", " & ", " x ", " vs. ", " vs ", " with "]
        let lower = artist.lowercased()
        var cut = artist.count
        for sep in separators {
            if let r = lower.range(of: sep) {
                cut = min(cut, lower.distance(from: lower.startIndex, to: r.lowerBound))
            }
        }
        let primary = String(artist.prefix(cut)).trimmingCharacters(in: .whitespaces)
        return primary.isEmpty ? artist : primary
    }

    /// Drops Hangul and parentheses, collapsing whitespace, to recover the
    /// English title LRCLIB indexes under: "하늘 위로 Up" → "Up". Empty if the
    /// title is purely Hangul (caller then keeps the original).
    static func simplifiedTitle(_ title: String) -> String {
        let noHangul = String(title.unicodeScalars.filter { u in
            let v = u.value
            return !((0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v))
        })
        var s = noHangul.replacingOccurrences(of: "(", with: " ").replacingOccurrences(of: ")", with: " ")
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// True if any line contains a Hangul scalar (so romanised lyrics test false).
    static func containsHangul(_ lines: [LyricLine]) -> Bool {
        for line in lines {
            for u in line.text.unicodeScalars {
                let v = u.value
                if (0xAC00...0xD7A3).contains(v) || (0x1100...0x11FF).contains(v) || (0x3130...0x318F).contains(v) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - /api/get

    /// Returns the canonical synced lyrics (nil = LRCLIB has no synced canonical
    /// for this query), plus `failed` = the request hard-failed transiently (504
    /// /non-JSON/network) after retries. A `failed` request gives no information,
    /// so the caller must treat "no lyrics anywhere" as a failure, not an empty.
    private static func getExact(_ track: NowPlaying, artist: String, title: String) -> (lines: [LyricLine]?, failed: Bool) {
        var comps = URLComponents(string: "https://lrclib.net/api/get")!
        comps.queryItems = [
            .init(name: "artist_name", value: artist),
            .init(name: "track_name", value: title),
            .init(name: "album_name", value: track.album),
            .init(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        guard case .value(let json) = getJSON(comps.url) else { return (nil, true) }
        // Definitive JSON answer (possibly a 404 object, or a hit without synced
        // lyrics): not a failure, just no usable canonical.
        guard let dict = json as? [String: Any],
              let synced = dict["syncedLyrics"] as? String else { return (nil, false) }
        return (parseLRC(synced), false)
    }

    // MARK: - /api/search

    /// Synced search hits, filtered to the right cut and ranked: exact title
    /// first (so "Dynamite" beats "Dynamite - EDM Remix"), then closest duration.
    /// `failed` = the search request hard-failed transiently after retries (so an
    /// empty candidate list means "nothing found", not "the request died").
    private static func searchCandidates(_ track: NowPlaying, artist: String, title: String) -> (candidates: [Candidate], failed: Bool) {
        var comps = URLComponents(string: "https://lrclib.net/api/search")!
        comps.queryItems = [.init(name: "q", value: "\(artist) \(title)")]
        guard case .value(let json) = getJSON(comps.url) else { return ([], true) }
        guard let arr = json as? [[String: Any]] else { return ([], false) }

        let wantTitle = title.lowercased()
        let scored = arr.compactMap { hit -> (Int, Double, [LyricLine])? in
            guard let synced = hit["syncedLyrics"] as? String, !synced.isEmpty else { return nil }
            let dur = (hit["duration"] as? NSNumber)?.doubleValue ?? 0
            let delta = abs(dur - track.duration)
            if track.duration > 0 && delta > 7 { return nil }   // not the same cut
            let lines = parseLRC(synced)
            if lines.isEmpty { return nil }
            let name = (hit["trackName"] as? String ?? "").lowercased()
            let titleRank = name == wantTitle ? 0 : (name.hasPrefix(wantTitle) ? 1 : 2)
            return (titleRank, delta, lines)
        }
        let ranked = scored
            .sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            .map { Candidate(lines: $0.2) }
        return (ranked, false)
    }

    // MARK: - networking

    /// Outcome of a single LRCLIB request. We must tell a *definitive* answer
    /// (the server replied with valid JSON — even a 404 "track not found" object
    /// counts) from a *transient failure* (504 gateway HTML, an empty body, or a
    /// curl/network error), because only the latter should be retried upstream and
    /// must never be cached as "no lyrics". A parse failure ⇒ transient; a
    /// successful parse ⇒ definitive, even when the JSON is a 404 error object.
    private enum JSONResult {
        case value(Any)   // server replied with parseable JSON (the definitive answer)
        case failure      // 504/non-JSON/empty/network error after retries — retry upstream
    }

    /// Shells out to `curl`. URLSession requests stall to ~8s under this app's
    /// AppKit run loop (bundle-less GUI executable), but a subprocess is immune —
    /// the same reason the MediaRemote bridge uses `osascript`.
    ///
    /// Bounded retry: under the concurrent /api/get + /api/search load LRCLIB
    /// frequently answers a single request with an nginx 504 Gateway Time-out HTML
    /// page (not JSON). That body fails to parse, so we retry a couple of times with
    /// a short backoff — a retry almost always succeeds. We only retry parse
    /// failures: a *valid* JSON body (including LRCLIB's 404 "not found" object) is
    /// a real answer and is returned immediately, never retried.
    private static func getJSON(_ url: URL?) -> JSONResult {
        guard let url else { return .failure }
        let backoffs: [Double] = [0.3, 0.6]   // delays AFTER attempts 1 and 2; 3 attempts total
        for attempt in 0...backoffs.count {
            if let json = curlJSON(url) { return .value(json) }
            // Parse failed (504 HTML, empty body, or curl error) → transient. Back
            // off briefly and retry, unless this was the last attempt.
            if attempt < backoffs.count { Thread.sleep(forTimeInterval: backoffs[attempt]) }
        }
        return .failure
    }

    /// One curl invocation. Returns the parsed JSON, or nil if the body didn't
    /// parse (a 504 HTML page, an empty body, or a curl/network error) — the caller
    /// treats nil as a transient failure worth retrying.
    private static func curlJSON(_ url: URL) -> Any? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-s", "--max-time", "10", "-H", "User-Agent: \(userAgent)", url.absoluteString]

        let pipe = Pipe()
        proc.standardOutput = pipe
        // Discard stderr (not just leave it unread): a full, undrained stderr pipe
        // would block curl → stdout never closes → readDataToEndOfFile() hangs.
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return try? JSONSerialization.jsonObject(with: data)
    }

    // MARK: - LRC parsing

    /// `[mm:ss.xx]` timestamp tag. Compiled once, reused across every parse.
    private static let tagRegex = try! NSRegularExpression(pattern: #"\[(\d+):(\d{2}(?:\.\d+)?)\]"#)

    /// Parses `[mm:ss.xx] text` lines (a line can carry multiple timestamps).
    static func parseLRC(_ raw: String) -> [LyricLine] {
        let tag = tagRegex
        var out: [LyricLine] = []

        for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            let ns = line as NSString
            let matches = tag.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }

            let text = ns
                .substring(from: last.range.location + last.range.length)
                .trimmingCharacters(in: .whitespaces)

            for m in matches {
                let mm = Double(ns.substring(with: m.range(at: 1))) ?? 0
                let ss = Double(ns.substring(with: m.range(at: 2))) ?? 0
                out.append(LyricLine(time: mm * 60 + ss, text: text))
            }
        }
        return out.sorted { $0.time < $1.time }
    }
}
