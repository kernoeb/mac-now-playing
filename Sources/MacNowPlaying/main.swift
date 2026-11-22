import Cocoa
import SwiftUI

/// Hosting view that forwards vertical scroll-wheel input — used to calibrate
/// the lyric sync offset by scrolling over the overlay.
final class ScrollHostingView<V: View>: NSHostingView<V> {
    var onScroll: ((CGFloat) -> Void)?
    override func scrollWheel(with event: NSEvent) {
        let dy = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.deltaY
        if dy != 0 { onScroll?(dy) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private let model = PlayerModel()
    private var hoverTimer: Timer?
    private var activity: NSObjectProtocol?
    private var menuBar: MenuBar?
    // Retained for the app's lifetime; PlayerModel drives presence through it.
    private let discord = DiscordRPC()

    // Height of the interactive band over the current line — one lyric row
    // (matches LyricsView.rowHeight). Only here is the window non-click-through.
    private static let centerBandHeight: CGFloat = 54

    // Distance from the window's bottom edge up to the centre of the current line.
    // MUST match LyricsView.currentLineFromBottom so the scroll band lands on it.
    private static let currentLineFromBottom: CGFloat = 78

    // The interactive region is only as WIDE as the current line's rendered text
    // (centred) — so the empty margins on either side stay click-through and the
    // overlay only catches the mouse where glyphs actually are. Font size/weight and
    // horizontal padding MUST match LyricsView (currentSize / .bold / padding 34).
    private static let currentLineFont = NSFont.systemFont(ofSize: 30, weight: .bold)
    private static let textHPadding: CGFloat = 34
    // A little slack around the glyphs so the text stays comfortable to hover/scroll.
    private static let hitMargin: CGFloat = 16

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Prevent App Nap from throttling our polling + network while unfocused,
        // but still allow the Mac to idle-sleep normally — a passive overlay has
        // no business keeping the machine awake. (.userInitiated would imply
        // .idleSystemSleepDisabled; the …AllowingIdleSystemSleep variant doesn't.)
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: "Live lyrics overlay"
        )

        let width: CGFloat = 1000
        let height: CGFloat = 180

        // Always the primary (menu-bar) display — screens[0] — not NSScreen.main,
        // which would be wherever focus happened to be at launch. Use visibleFrame
        // so the window sits just ABOVE the Dock (it occupies ~82pt at the bottom);
        // the lyrics hug this window's bottom edge (see LyricsView).
        let primary = NSScreen.screens.first ?? NSScreen.main
        let bounds = primary?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let visible = primary?.visibleFrame ?? bounds
        let frame = NSRect(
            x: bounds.midX - width / 2,
            y: visible.minY + 2,
            width: width,
            height: height
        )

        window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .floating
        window.ignoresMouseEvents = true   // click-through HUD
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

        let host = ScrollHostingView(rootView: LyricsView().environmentObject(model))
        host.onScroll = { [weak self] dy in
            // Scale the correction by how hard you scroll: a gentle nudge fine-tunes
            // (~0.02s), a firm flick covers whole seconds — so a 3–4s shift is a quick
            // gesture, not 70 ticks. Magnitude clamped per-event to stay controllable.
            let step = min(0.5, max(0.02, abs(dy) * 0.02))
            MainActor.assumeIsolated { self?.model.nudgeSync(by: dy > 0 ? step : -step) }
        }
        host.frame = NSRect(origin: .zero, size: frame.size)
        host.autoresizingMask = [.width, .height]
        window.contentView = host
        // Stays hidden until there's something to show; the timer below brings it
        // on/off screen as music + lyrics come and go.

        // Cheap, permission-free hover detection: poll the cursor position and
        // check whether it's inside the overlay's frame.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {       // Timer fires on the main run loop
                guard let self else { return }

                // Show the window only when there's something to display AND the
                // user hasn't disabled the overlay from the menubar; otherwise take
                // it off screen entirely so it can't catch hover or scroll.
                let show = self.model.hasContent && self.model.overlayEnabled
                if self.window.isVisible != show {
                    if show {
                        self.window.orderFrontRegardless()
                    } else {
                        self.window.orderOut(nil)
                        self.model.isHovering = false
                        self.window.ignoresMouseEvents = true
                    }
                }
                guard show else { return }

                // Only the current line's visible text is interactive: a centred band
                // sized to the rendered glyphs (see currentLineRect). The cursor there
                // captures scroll (to calibrate) and brightens the overlay; everywhere
                // else — including the empty margins beside the text — the window stays
                // click-through, so it never blocks the large area it covers.
                let onText = self.currentLineRect(in: self.window.frame)?
                    .contains(NSEvent.mouseLocation) ?? false
                if onText != self.model.isHovering {
                    self.model.isHovering = onText
                    self.window.ignoresMouseEvents = !onText
                }
            }
        }

        // Inject the Discord client so PlayerModel can publish Rich Presence (a
        // parallel consumer of the now-playing engine, independent of the overlay).
        model.discord = discord

        // Retain the menubar status item — without a strong reference it vanishes.
        menuBar = MenuBar(model: model)

        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Don't leave a stale "Listening to LocalMusic" presence behind on quit.
        discord.clear()
        discord.disconnect()
    }

    /// Screen-space rect of the current lyric line's visible text: a centred band
    /// just wide enough for the rendered glyphs (clamped to the text area, plus a
    /// little slack), one row tall, at the current-line position. `nil` when there's
    /// no line to target (no lyrics yet / still loading) — then nothing is interactive
    /// and the whole window is click-through.
    private func currentLineRect(in frame: NSRect) -> NSRect? {
        let lines = model.lines
        guard !lines.isEmpty else { return nil }
        // Before the first line starts (currentIndex == -1) the upcoming line 0 is the
        // sensible target; otherwise clamp into range defensively.
        let idx = max(0, min(model.currentIndex, lines.count - 1))
        let text = lines[idx].text.isEmpty ? "♪" : lines[idx].text

        let maxContentWidth = frame.width - 2 * Self.textHPadding
        let measured = (text as NSString).size(withAttributes: [.font: Self.currentLineFont]).width
        // minimumScaleFactor shrinks an over-long line to fit the text area, so the
        // rendered width never exceeds maxContentWidth.
        let width = min(measured, maxContentWidth) + 2 * Self.hitMargin

        return NSRect(
            x: frame.midX - width / 2,
            y: frame.minY + Self.currentLineFromBottom - Self.centerBandHeight / 2,
            width: width,
            height: Self.centerBandHeight
        )
    }
}

// Debug: `MacNowPlaying --now` → print the current MediaRemote read once, exit.
if CommandLine.arguments.contains("--now") {
    if let np = MediaRemoteBridge.query() {
        print("NOW → \(np.artist) — \(np.title)  [playing=\(np.isPlaying) rate=\(np.rate) " +
              "elapsed=\(np.elapsed) dur=\(np.duration) source=\(np.sourceBundle.isEmpty ? "?" : np.sourceBundle)]")
    } else {
        print("NOW → nothing playing")
    }
    exit(0)
}

// Debug: `MacNowPlaying --probe "Artist" "Title" duration` → fetch + print, exit.
if CommandLine.arguments.first(where: { $0 == "--probe" }) != nil {
    let a = CommandLine.arguments
    guard a.count >= 5 else {
        FileHandle.standardError.write("usage: MacNowPlaying --probe \"Artist\" \"Title\" <duration>\n".data(using: .utf8)!)
        exit(2)
    }
    let np = NowPlaying(title: a[3], artist: a[2], album: "",
                        duration: Double(a[4]) ?? 0, elapsed: 0, timestamp: 0,
                        isPlaying: true, rate: 1, sourceBundle: "", sourcePID: 0)
    // nil = transient failure (504/non-JSON/network) — distinct from a definitive
    // empty result, which prints "0 lines".
    guard let lines = LRCLIB.fetchSynced(for: np) else {
        FileHandle.standardError.write("PROBE → FAILED (transient: 504/non-JSON/network)\n".data(using: .utf8)!)
        exit(1)
    }
    FileHandle.standardError.write("PROBE → \(lines.count) lines\n".data(using: .utf8)!)
    for l in lines.prefix(4) {
        FileHandle.standardError.write("  [\(l.time)] \(l.text)\n".data(using: .utf8)!)
    }
    exit(0)
}

// Debug: `MacNowPlaying --art "Artist" "Title"` → print the whole resolver chain
// (iTunes hit, YouTube-thumbnail hit, and the resolved final URL), exit. Lets you
// verify the iTunes → YouTube fallback order end-to-end.
if CommandLine.arguments.contains("--art") {
    let a = CommandLine.arguments
    guard a.count >= 4, let i = a.firstIndex(of: "--art"), i + 2 < a.count else {
        FileHandle.standardError.write("usage: MacNowPlaying --art \"Artist\" \"Title\"\n".data(using: .utf8)!)
        exit(2)
    }
    let artist = a[i + 1], title = a[i + 2]
    print("iTunes → \(Artwork.iTunesCoverURL(title: title, artist: artist, album: "") ?? "no match")")
    print("YouTube → \(Artwork.youTubeThumbnailURL(title: title, artist: artist) ?? "no match")")
    if let url = Artwork.coverURL(title: title, artist: artist, album: "") {
        print("resolved → \(url)")
        exit(0)
    } else {
        FileHandle.standardError.write("resolved → no match\n".data(using: .utf8)!)
        exit(1)
    }
}

// Debug: `MacNowPlaying --discord` → connect, send a test activity, hold ~3s so you
// can eyeball Discord, then clear + exit. End-to-end IPC check.
if CommandLine.arguments.contains("--discord") {
    let rpc = DiscordRPC()
    let group = DispatchGroup()
    group.enter()
    rpc.connect { found, ready in
        print("socket found: \(found)")
        print("READY received: \(ready)")
        guard found, ready else {
            print(found ? "handshake failed" : "Discord not running")
            group.leave()
            return
        }
        let now = Date()
        rpc.setActivity(.init(
            name: "Test Title - Test Artist",
            details: "Test Title",
            state: "Test Artist",
            start: now,
            end: now.addingTimeInterval(180),
            largeImage: "spotify",          // asset key fallback (renders once uploaded)
            largeImageText: "Test Album",
            smallImage: "spotify",          // source badge (renders once uploaded)
            smallImageText: "Spotify"
        )) { sent in
            print("activity sent: \(sent)")
            group.leave()
        }
    }
    group.wait()
    // Hold briefly so the presence is visible in Discord, then clear and exit.
    Thread.sleep(forTimeInterval: 3)
    rpc.clear()
    Thread.sleep(forTimeInterval: 0.3)   // let the clear flush before we exit
    rpc.disconnect()
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon; pure overlay agent
    app.run()
}
