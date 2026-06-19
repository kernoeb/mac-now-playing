import Cocoa

/// The menubar status item and its dropdown menu. Mirrors the sibling project's
/// systray: a template music-note icon, a disabled now-playing status row at the
/// top, then the actionable items, then Quit. Adapted for this overlay app — the
/// original's Pause/Resume of presence updates becomes a "Show Overlay" toggle.
///
/// Owned (and retained) by `AppDelegate`; an `NSStatusItem` with no strong
/// reference is released and silently vanishes from the menubar.
@MainActor
final class MenuBar: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let model: PlayerModel

    // Menu items we mutate from state — kept as references so we don't rebuild the
    // menu each time. The status row shows the current track; the toggle reflects
    // model.overlayEnabled.
    private let nowPlayingItem: NSMenuItem
    private let showOverlayItem: NSMenuItem
    private let discordItem: NSMenuItem

    init(model: PlayerModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        nowPlayingItem = NSMenuItem(title: "Nothing playing", action: nil, keyEquivalent: "")
        nowPlayingItem.isEnabled = false

        showOverlayItem = NSMenuItem(
            title: "Show Overlay",
            action: #selector(toggleOverlay(_:)),
            keyEquivalent: ""
        )

        discordItem = NSMenuItem(
            title: "Discord Rich Presence",
            action: #selector(toggleDiscord(_:)),
            keyEquivalent: ""
        )

        super.init()

        // The tray icon (a 44x44 template PNG, the music note from the sibling
        // telegram-audio-discord project), bundled via SwiftPM resources. It's
        // square, so it never squashes; isTemplate lets macOS tint it for light/dark
        // menubars. Size below is tuned to the original's menubar footprint.
        if let button = statusItem.button {
            let image = Bundle.module.url(forResource: "tray-icon", withExtension: "png")
                .flatMap { NSImage(contentsOf: $0) }
            image?.isTemplate = true
            image?.size = NSSize(width: 16, height: 16)
            button.image = image
            button.toolTip = "Now Playing"
        }

        let menu = NSMenu()
        menu.delegate = self

        showOverlayItem.target = self
        showOverlayItem.state = model.overlayEnabled ? .on : .off

        discordItem.target = self
        discordItem.state = model.discordEnabled ? .on : .off

        let quitItem = NSMenuItem(
            title: "Quit",
            action: #selector(quit(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self

        menu.addItem(nowPlayingItem)
        menu.addItem(.separator())
        menu.addItem(showOverlayItem)
        menu.addItem(discordItem)
        menu.addItem(.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Refresh the now-playing row and toggle state right before the menu opens —
    /// cheaper than a continuous loop, and the menu is the only place they're seen.
    func menuNeedsUpdate(_ menu: NSMenu) {
        nowPlayingItem.title = model.nowPlayingDescription
        showOverlayItem.state = model.overlayEnabled ? .on : .off
        discordItem.state = model.discordEnabled ? .on : .off
    }

    @objc private func toggleOverlay(_ sender: NSMenuItem) {
        model.overlayEnabled.toggle()
        sender.state = model.overlayEnabled ? .on : .off
    }

    @objc private func toggleDiscord(_ sender: NSMenuItem) {
        // PlayerModel reacts in discordEnabled.didSet: OFF clears presence, ON
        // re-publishes the current track.
        model.discordEnabled.toggle()
        sender.state = model.discordEnabled ? .on : .off
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }
}
