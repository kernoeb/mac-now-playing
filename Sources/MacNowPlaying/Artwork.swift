import Foundation

/// Resolves album cover art for a track via the iTunes Search API.
///
/// Discord's `large_image` can't take local artwork bytes — it needs a pre-uploaded
/// asset key OR an external `https://` URL. So instead of shipping the system's local
/// artwork we look up a publicly-reachable cover URL per track and hand that to the
/// Rich Presence activity. This is a faithful port of how the sibling
/// `telegram-audio-discord` project resolves art.
///
/// Like `LRCLIB`, networking shells out to `/usr/bin/curl`: `URLSession` (every
/// variant) stalls ~8s under this app's AppKit run loop, but a subprocess returns
/// normally (see CLAUDE.md). Call `coverURL` from a background queue — it blocks.
enum Artwork {
    /// Resolve a cover URL for a track, trying each source in order and returning the
    /// first hit (or nil when none match). The chain mirrors the sibling
    /// `telegram-audio-discord` project's art assembly.
    ///
    /// ORDER (intentionally a single, obvious, easily-swapped sequence — the user wants
    /// iTunes-first parity for now but may flip iTunes/YouTube later, so keep this as
    /// one ordered list, not logic scattered across call sites):
    ///   1. iTunes Search API   (`iTunesCoverURL`)
    ///   2. YouTube thumbnail   (`youTubeThumbnailURL`)
    /// To reorder, just rearrange the calls below.
    ///
    /// Resilient by design: every step's transient failure → nil, so the caller falls
    /// through to the next source and ultimately shows no art rather than crashing.
    static func coverURL(title: String, artist: String, album: String) -> String? {
        if let itunes = iTunesCoverURL(title: title, artist: artist, album: album) {
            return itunes
        }
        if let youtube = youTubeThumbnailURL(title: title, artist: artist) {
            return youtube
        }
        return nil
    }

    /// Resolve a 512×512 cover URL for a track via the iTunes Search API, or nil when
    /// nothing suitable is found. Builds an iTunes search term from the title + first
    /// artist, queries the Search API, and returns the first result whose artwork exists
    /// AND plausibly matches the track (see `matchesResult`), upgraded from the API's
    /// 100×100 thumbnail to 512×512.
    ///
    /// Resilient by design: a transient curl/JSON failure (or no match) returns nil —
    /// the caller simply falls through to the next source.
    static func iTunesCoverURL(title: String, artist: String, album: String) -> String? {
        // Use the shared lead-artist extractor so art and lyrics search the same act.
        let first = LRCLIB.primaryArtist(artist)
        // Search term mirrors the sibling project: "<title> <firstArtist>", normalized.
        let term = normalizeSearchTerm("\(title) \(first)")
        guard !term.isEmpty else { return nil }

        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [
            .init(name: "term", value: term),
            .init(name: "media", value: "music"),
            .init(name: "entity", value: "song"),
            .init(name: "limit", value: "10"),
        ]
        guard let json = curlJSON(comps.url),
              let dict = json as? [String: Any],
              let results = dict["results"] as? [[String: Any]] else { return nil }

        for result in results {
            guard let art = result["artworkUrl100"] as? String, !art.isEmpty else { continue }
            let resultArtist = (result["artistName"] as? String) ?? ""
            let resultTitle = (result["trackName"] as? String) ?? ""
            if matchesResult(artist: artist, title: title,
                             resultArtist: resultArtist, resultTitle: resultTitle) {
                // Upgrade resolution: the API hands back a 100×100 thumbnail.
                return art.replacingOccurrences(of: "100x100", with: "512x512")
            }
        }
        return nil
    }

    /// Resolve a cover via a YouTube thumbnail: scrape the YouTube results page for the
    /// FIRST video id and build its `maxresdefault.jpg` URL. Ports the sibling project's
    /// `searchYouTubeThumbnail` — same normalized "<title> <firstArtist>" search term as
    /// the iTunes lookup. Returns nil on any transient failure (no body / no id).
    ///
    /// NOTE: `maxresdefault.jpg` does not exist for every video (some only have
    /// `hqdefault.jpg`); the original accepts that risk and so do we — a 404 thumbnail
    /// just renders as no image in Discord, never a crash.
    static func youTubeThumbnailURL(title: String, artist: String) -> String? {
        let first = LRCLIB.primaryArtist(artist)
        let term = normalizeSearchTerm("\(title) \(first)")
        guard !term.isEmpty,
              let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://www.youtube.com/results?search_query=\(encoded)"),
              let html = curlText(url),
              let videoID = firstYouTubeVideoID(inResultsHTML: html) else { return nil }
        return "https://i.ytimg.com/vi/\(videoID)/maxresdefault.jpg"
    }

    // MARK: - Pure helpers (testable)

    /// Extract the FIRST YouTube video id from a results-page HTML string, or nil if
    /// none is present. Pure (no networking) so it's unit-testable. Matches the same
    /// `"videoId":"<11 chars>"` token the sibling project's regex looks for.
    static func firstYouTubeVideoID(inResultsHTML html: String) -> String? {
        let pattern = #""videoId":"([a-zA-Z0-9_-]{11})""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(html.startIndex..., in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              let idRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[idRange])
    }

    /// NFD-normalize, strip diacritics, strip punctuation, collapse whitespace,
    /// lowercase. Ports the sibling project's `normalizeSearchTerm`.
    static func normalizeSearchTerm(_ s: String) -> String {
        // Decompose then drop combining marks (diacritics).
        let decomposed = s.decomposedStringWithCanonicalMapping
        let noDiacritics = String(decomposed.unicodeScalars.filter {
            !CharacterSet.nonBaseCharacters.contains($0)
        })
        // Keep letters/numbers/whitespace; everything else becomes a space.
        let cleaned = String(noDiacritics.unicodeScalars.map {
            (CharacterSet.alphanumerics.contains($0) || CharacterSet.whitespaces.contains($0))
                ? Character($0) : " "
        })
        let collapsed = cleaned.replacingOccurrences(
            of: #"\s+"#, with: " ", options: .regularExpression)
        return collapsed.trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// Does an iTunes result plausibly match the track? Ports `matchesResult`:
    /// artist matches if one contains the other or they share a >2-char word; title
    /// matches if any >2-char word overlaps or one contains the other. Both must hold.
    static func matchesResult(artist: String, title: String,
                              resultArtist: String, resultTitle: String) -> Bool {
        return fieldMatches(artist, resultArtist) && fieldMatches(title, resultTitle)
    }

    /// One field's fuzzy match: normalize both, then accept if either contains the
    /// other or they share any word longer than 2 characters.
    private static func fieldMatches(_ a: String, _ b: String) -> Bool {
        let na = normalizeSearchTerm(a)
        let nb = normalizeSearchTerm(b)
        if na.isEmpty || nb.isEmpty { return false }
        if na.contains(nb) || nb.contains(na) { return true }
        let wordsA = Set(na.split(separator: " ").map(String.init).filter { $0.count > 2 })
        let wordsB = Set(nb.split(separator: " ").map(String.init).filter { $0.count > 2 })
        return !wordsA.isDisjoint(with: wordsB)
    }

    // MARK: - networking

    /// One curl invocation. Returns parsed JSON, or nil on a non-JSON/empty body or a
    /// curl/network error. Mirrors `LRCLIB.curlJSON`: stdout pipe, stderr → nullDevice
    /// (an undrained full stderr pipe would deadlock the child), `JSONSerialization`.
    private static func curlJSON(_ url: URL?) -> Any? {
        guard let url else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = ["-s", "--max-time", "10", "-H", "User-Agent: \(LRCLIB.userAgent)", url.absoluteString]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        return try? JSONSerialization.jsonObject(with: data)
    }

    /// One curl invocation returning the raw response body as text, or nil on a
    /// curl/network error or empty body. Same subprocess style as `curlJSON`, but for
    /// the YouTube results page we send a browser-like User-Agent and Accept-Language
    /// (matching the sibling project) so YouTube serves the normal HTML with the
    /// `ytInitialData` we scrape, not a stripped/consent page.
    private static func curlText(_ url: URL?) -> String? {
        guard let url else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        proc.arguments = [
            "-s", "--max-time", "10",
            "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
            "-H", "Accept-Language: en-US,en;q=0.9",
            url.absoluteString,
        ]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()

        let text = String(data: data, encoding: .utf8)
        return (text?.isEmpty ?? true) ? nil : text
    }
}
