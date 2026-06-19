import XCTest
@testable import MacNowPlaying

/// Covers the PURE source-allowlist logic in `MediaSource` (bundle allowlist, the
/// Telegram voice-message regex, the YT Music extension-suffix check). The impure
/// `app_mode_loader` `ps` branch is environment-dependent and intentionally not
/// unit-tested here.
final class MediaSourceTests: XCTestCase {

    // pid 0 keeps us off the impure `ps` branch for every case below.

    // MARK: - Spotify

    func testSpotifyIsMusic() {
        XCTAssertTrue(MediaSource.isMusic(bundle: "com.spotify.client", title: "Any Song", pid: 0))
    }

    // MARK: - Telegram

    func testTelegramNormalTitleIsMusic() {
        XCTAssertTrue(MediaSource.isMusic(bundle: "ru.keepcoder.Telegram", title: "Some Song", pid: 0))
        XCTAssertTrue(MediaSource.isMusic(bundle: "org.telegram.desktop", title: "Daft Punk - One More Time", pid: 0))
        XCTAssertTrue(MediaSource.isMusic(bundle: "com.tdesktop.Telegram", title: "Track 01", pid: 0))
    }

    func testTelegramVoiceMessageIsNotMusic() {
        XCTAssertFalse(MediaSource.isMusic(bundle: "ru.keepcoder.Telegram", title: "today at 8:12 PM", pid: 0))
        XCTAssertFalse(MediaSource.isMusic(bundle: "org.telegram.desktop", title: "aujourd'hui à 20:12", pid: 0))
        XCTAssertFalse(MediaSource.isMusic(bundle: "com.tdesktop.Telegram", title: "hier à 15:30", pid: 0))
    }

    // MARK: - isTelegramVoiceMessage (pure helper)

    func testIsTelegramVoiceMessagePatterns() {
        XCTAssertTrue(MediaSource.isTelegramVoiceMessage("today at 8:12 PM"))
        XCTAssertTrue(MediaSource.isTelegramVoiceMessage("aujourd'hui à 20:12"))
        XCTAssertTrue(MediaSource.isTelegramVoiceMessage("hier à 15:30"))
        XCTAssertTrue(MediaSource.isTelegramVoiceMessage("9:05"))
    }

    func testIsTelegramVoiceMessageRejectsNormalTitles() {
        XCTAssertFalse(MediaSource.isTelegramVoiceMessage("One More Time"))
        // Ends in a time but is too long (> 40 chars) to be a voice-message timestamp.
        XCTAssertFalse(MediaSource.isTelegramVoiceMessage("A really long song name that happens to end 8:12 PM"))
        // A time not at the end isn't a voice-message title.
        XCTAssertFalse(MediaSource.isTelegramVoiceMessage("8:12 PM remix edit"))
    }

    // MARK: - YouTube Music

    func testYouTubeMusicExtensionSuffixIsMusic() {
        XCTAssertTrue(MediaSource.isMusic(
            bundle: "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod",
            title: "Some Song", pid: 0))
        XCTAssertTrue(MediaSource.isMusic(
            bundle: "com.brave.Browser.app.cinhimbnkkaeohfgghhklpknlkffjgod",
            title: "Some Song", pid: 0))
    }

    // MARK: - Non-music sources

    func testUnknownAndBrowserBundlesAreNotMusic() {
        XCTAssertFalse(MediaSource.isMusic(bundle: "com.apple.Safari", title: "Some YouTube Video", pid: 0))
        XCTAssertFalse(MediaSource.isMusic(bundle: "com.kernoeb.secousse", title: "Anything", pid: 0))
        XCTAssertFalse(MediaSource.isMusic(bundle: "", title: "Anything", pid: 0))
        // app_mode_loader with no pid can't be verified → not music.
        XCTAssertFalse(MediaSource.isMusic(bundle: "app_mode_loader", title: "Anything", pid: 0))
    }

    // MARK: - classify (the Source the gate returns)

    func testClassifyReturnsTheRightSource() {
        XCTAssertEqual(MediaSource.classify(bundle: "com.spotify.client", title: "Any Song", pid: 0), .spotify)
        XCTAssertEqual(MediaSource.classify(bundle: "ru.keepcoder.Telegram", title: "Some Song", pid: 0), .telegram)
        XCTAssertEqual(MediaSource.classify(bundle: "org.telegram.desktop", title: "Some Song", pid: 0), .telegram)
        XCTAssertEqual(MediaSource.classify(
            bundle: "com.google.Chrome.app.cinhimbnkkaeohfgghhklpknlkffjgod",
            title: "Some Song", pid: 0), .youTubeMusic)
    }

    func testClassifyReturnsNilForNonMusic() {
        XCTAssertNil(MediaSource.classify(bundle: "com.apple.Safari", title: "Some Video", pid: 0))
        XCTAssertNil(MediaSource.classify(bundle: "com.kernoeb.secousse", title: "Anything", pid: 0))
        XCTAssertNil(MediaSource.classify(bundle: "", title: "Anything", pid: 0))
        XCTAssertNil(MediaSource.classify(bundle: "app_mode_loader", title: "Anything", pid: 0))
    }

    func testClassifyRejectsTelegramVoiceMessage() {
        XCTAssertNil(MediaSource.classify(bundle: "ru.keepcoder.Telegram", title: "today at 8:12 PM", pid: 0))
        XCTAssertNil(MediaSource.classify(bundle: "org.telegram.desktop", title: "aujourd'hui à 20:12", pid: 0))
    }

    func testSourceImageKeyAndLabel() {
        XCTAssertEqual(MediaSource.Source.spotify.imageKey, "spotify")
        XCTAssertEqual(MediaSource.Source.telegram.imageKey, "telegram")
        XCTAssertEqual(MediaSource.Source.youTubeMusic.imageKey, "youtube-music")
        XCTAssertEqual(MediaSource.Source.spotify.label, "Spotify")
        XCTAssertEqual(MediaSource.Source.telegram.label, "Telegram")
        XCTAssertEqual(MediaSource.Source.youTubeMusic.label, "YouTube Music")
    }
}
