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

    // Height of the interactive band over the current line — one lyric row
    // (matches LyricsView.rowHeight). Only here is the window non-click-through.
    private static let centerBandHeight: CGFloat = 54

    // Distance from the window's bottom edge up to the centre of the current line.
    // MUST match LyricsView.currentLineFromBottom so the scroll band lands on it.
    private static let currentLineFromBottom: CGFloat = 78

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

                // Show the window only when there's something to display; otherwise
                // take it off screen entirely so it can't catch hover or scroll.
                let show = self.model.hasContent
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

                // Only the current line is interactive: a one-row band over it near the
                // window's bottom. The cursor there captures scroll (to calibrate) and
                // brightens the overlay; everywhere else the window stays click-through,
                // so it never blocks the large, mostly-empty area it covers.
                let f = self.window.frame
                let band = NSRect(x: f.minX,
                                  y: f.minY + Self.currentLineFromBottom - Self.centerBandHeight / 2,
                                  width: f.width, height: Self.centerBandHeight)
                let onLine = band.contains(NSEvent.mouseLocation)
                if onLine != self.model.isHovering {
                    self.model.isHovering = onLine
                    self.window.ignoresMouseEvents = !onLine
                }
            }
        }

        model.start()
    }
}

// Debug: `LyricsOverlay --probe "Artist" "Title" duration` → fetch + print, exit.
if CommandLine.arguments.first(where: { $0 == "--probe" }) != nil {
    let a = CommandLine.arguments
    guard a.count >= 5 else {
        FileHandle.standardError.write("usage: LyricsOverlay --probe \"Artist\" \"Title\" <duration>\n".data(using: .utf8)!)
        exit(2)
    }
    let np = NowPlaying(title: a[3], artist: a[2], album: "",
                        duration: Double(a[4]) ?? 0, elapsed: 0, timestamp: 0,
                        isPlaying: true, rate: 1)
    let lines = LRCLIB.fetchSynced(for: np)
    FileHandle.standardError.write("PROBE → \(lines.count) lines\n".data(using: .utf8)!)
    for l in lines.prefix(4) {
        FileHandle.standardError.write("  [\(l.time)] \(l.text)\n".data(using: .utf8)!)
    }
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)   // no Dock icon; pure overlay agent
    app.run()
}
