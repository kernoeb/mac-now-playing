import XCTest
@testable import MacNowPlaying

final class LyricsCacheTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LyricsCacheTests-\(UUID().uuidString)", isDirectory: true)
        LyricsCache.overrideDirectory = tempDir
    }

    override func tearDownWithError() throws {
        LyricsCache.overrideDirectory = nil
        try? FileManager.default.removeItem(at: tempDir)
    }

    func testMissReturnsNil() {
        XCTAssertNil(LyricsCache.load("Nobody|Nothing"))
    }

    func testRoundTripsLyrics() {
        let lines = [LyricLine(time: 1.5, text: "hello"), LyricLine(time: 65.5, text: "world")]
        LyricsCache.save(lines, for: "Band|Song")
        XCTAssertEqual(LyricsCache.load("Band|Song"), lines)
    }

    func testStoredEmptyIsDistinctFromAMiss() {
        // A genuine "no synced lyrics" empty must come back as [] (a real cached
        // answer), not nil (never stored) — otherwise lyric-less tracks refetch
        // every session.
        LyricsCache.save([], for: "Band|Instrumental")
        XCTAssertEqual(LyricsCache.load("Band|Instrumental"), [])
        XCTAssertNil(LyricsCache.load("Band|NeverSeen"))
    }

    func testKeysWithFilesystemMetacharsDoNotCollide() {
        // trackKey is free-form "artist|title" and can contain "/" etc.; the hash
        // filename must keep distinct keys in distinct files.
        LyricsCache.save([LyricLine(time: 0, text: "a")], for: "AC/DC|T.N.T")
        LyricsCache.save([LyricLine(time: 0, text: "b")], for: "AC/DC|Hells Bells")
        XCTAssertEqual(LyricsCache.load("AC/DC|T.N.T")?.first?.text, "a")
        XCTAssertEqual(LyricsCache.load("AC/DC|Hells Bells")?.first?.text, "b")
    }
}
