import Foundation

enum MediaSource {
    enum Source: Equatable {
        case spotify, telegram, youTubeMusic, other

        var imageKey: String {
            switch self {
            case .spotify: return "spotify"
            case .telegram: return "telegram"
            case .youTubeMusic: return "youtube-music"
            case .other: return "youtube"
            }
        }

        var label: String {
            switch self {
            case .spotify: return "Spotify"
            case .telegram: return "Telegram"
            case .youTubeMusic: return "YouTube Music"
            case .other: return "YouTube"
            }
        }

        var activityType: Int {
            self == .other ? 3 : 2
        }
    }

    private static let spotifyBundle = "com.spotify.client"
    private static let telegramBundles: Set<String> = [
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "com.tdesktop.Telegram",
    ]
    private static let ytMusicExtensionID = "cinhimbnkkaeohfgghhklpknlkffjgod"

    static func classify(bundle: String, title: String, pid: Int32) -> Source? {
        if bundle == spotifyBundle || bundle == "com.apple.Music" || bundle == "com.apple.iTunes" { return .spotify }
        if telegramBundles.contains(bundle) {
            return isTelegramVoiceMessage(title) ? nil : .telegram
        }
        if bundle.hasSuffix(".\(ytMusicExtensionID)") { return .youTubeMusic }
        if bundle == "app_mode_loader", pid > 0 {
            return isYouTubeMusicProcess(pid: pid) ? .youTubeMusic : .other
        }
        return .other
    }

    static func isMusic(bundle: String, title: String, pid: Int32) -> Bool {
        return classify(bundle: bundle, title: title, pid: pid) != nil
    }

    static func isTelegramVoiceMessage(_ title: String) -> Bool {
        guard title.count <= 40 else { return false }
        let pattern = #"\d{1,2}:\d{2}(\s*(AM|PM))?$"#
        return title.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private struct CacheEntry { let isYtMusic: Bool; let at: Date }
    private static let cacheTTL: TimeInterval = 30
    private static let cacheLock = NSLock()
    private static var pidCache: [Int32: CacheEntry] = [:]

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

    private static func processArgs(pid: Int32) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/ps")
        proc.arguments = ["-p", String(pid), "-o", "args="]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice

        do { try proc.run() } catch { return nil }
        let watchdog = DispatchWorkItem { proc.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2, execute: watchdog)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        watchdog.cancel()
        return String(data: data, encoding: .utf8)
    }
}
