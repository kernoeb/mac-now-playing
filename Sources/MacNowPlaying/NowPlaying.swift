import Foundation

/// A snapshot of what macOS thinks is currently playing.
struct NowPlaying: Equatable {
    var title: String
    var artist: String
    var album: String
    var duration: Double      // seconds
    var elapsed: Double       // seconds, sampled at `timestamp`
    var timestamp: Double     // wall-clock (epoch seconds) when `elapsed` was sampled; 0 if unknown
    var isPlaying: Bool
    var rate: Double          // playback rate (0 when paused)

    /// Stable identity for "is this a different track than before?"
    /// Deliberately excludes duration — web players (YT Music) report it late or
    /// fluctuating, which would otherwise churn the key and re-fetch endlessly.
    var trackKey: String { "\(artist)|\(title)" }

    var isValid: Bool { !title.isEmpty && !artist.isEmpty }
}

/// Queries macOS now-playing state by running a JXA script through `osascript`.
///
/// Why a subprocess and not a native call (verified on 15.6, not assumed):
/// on macOS 15.4+ MediaRemote only serves now-playing data to **Apple-signed**
/// callers — platform binaries like `/usr/bin/osascript`, or Apple's own
/// team-signed tools. A third-party app is denied no matter how it asks: the
/// `MRNowPlayingRequest` ObjC accessor returns nil, and the async
/// `MRMediaRemoteGetNowPlayingInfo` C function fires its completion with an
/// EMPTY dict. Tested with both an ad-hoc-signed and an Apple-Development-signed
/// build — both denied; only the Apple-signed interpreter/`osascript` got data.
/// So we borrow the privilege of the platform binary `osascript`, which is
/// allowed. (`osascript` runs the same `MRNowPlayingRequest` class we'd call
/// natively — it's just the only host permitted to.)
///
/// This relies on a private, undocumented Apple framework: App Store ineligible,
/// and may change or break on any macOS update.
enum MediaRemoteBridge {
    private static let jxa = #"""
    ObjC.import("Foundation");
    function run() {
      try {
        const MR = $.NSBundle.bundleWithPath("/System/Library/PrivateFrameworks/MediaRemote.framework/");
        MR.load;
        const Req = $.NSClassFromString("MRNowPlayingRequest");
        if (!Req) return JSON.stringify({ error: "no MRNowPlayingRequest" });

        const out = { isPlaying: Req.localIsPlaying ? true : false };

        const item = Req.localNowPlayingItem;
        if (item && item.nowPlayingInfo) {
          const d = item.nowPlayingInfo, e = d.keyEnumerator;
          let k;
          while ((k = e.nextObject) && !k.isNil()) {
            const ks = ObjC.unwrap(k), v = d.objectForKey(k);
            const key2 = ks.replace("kMRMediaRemoteNowPlayingInfo", "");
            if (v && !v.isNil()) {
              if (v.isKindOfClass($.NSDate)) out[key2] = v.timeIntervalSince1970;
              else if (v.isKindOfClass($.NSNumber) || v.isKindOfClass($.NSString)) out[key2] = ObjC.unwrap(v);
            }
          }
        }
        return JSON.stringify(out);
      } catch (e) {
        return JSON.stringify({ error: e.toString() });
      }
    }
    """#

    /// Runs the JXA query. Blocking — call off the main thread.
    static func query() -> NowPlaying? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        proc.arguments = ["-l", "JavaScript", "-e", jxa]

        let pipe = Pipe()
        proc.standardOutput = pipe
        // Discard stderr: osascript has no timeout, so an UNREAD stderr pipe that
        // fills its buffer would block the child → stdout never closes → the
        // readDataToEndOfFile() below hangs forever. nullDevice can't fill up.
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            return nil
        }

        // osascript has no `--timeout`. If MediaRemote's XPC service wedges, the
        // read below would block forever — and because the poller only spawns a
        // new query once the previous one returns (its `isPolling` guard), a single
        // hung query freezes the overlay permanently. A watchdog kills an overrun
        // query so polling always recovers; terminating closes the pipe, so the
        // read unblocks and we fall through to the nil-returning JSON guard.
        let watchdog = DispatchWorkItem { proc.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            json["error"] == nil
        else { return nil }

        func str(_ k: String) -> String { (json[k] as? String) ?? "" }
        func num(_ k: String) -> Double { (json[k] as? NSNumber)?.doubleValue ?? 0 }

        return NowPlaying(
            title: str("Title"),
            artist: str("Artist"),
            album: str("Album"),
            duration: num("Duration"),
            elapsed: num("ElapsedTime"),
            timestamp: num("Timestamp"),
            isPlaying: (json["isPlaying"] as? Bool) ?? false,
            rate: num("PlaybackRate")
        )
    }
}
